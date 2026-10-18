class_name DmNextParty
extends Node
## Child "Party" of DmNextGame (every peer, same NodePath: its RPCs live here). The lobby side of 2-player co-op on the rebuilt client: a public list of Open sessions, Closed (invite-only) parties, hosting that turns the running solo session into a hosted one, joining that hands the
## player to the host's session, the roster / kick / Open-Closed controls, the guest's profile, and friends over the lobby (DECISIONS B18): presence, invites, asks to join.
## It talks to the TEST lobby and relay only (DmConfig.LOBBY_URL, DmConfig.allows_lobby_url / allows_relay): never the live ones before launch day (DECISIONS B38).
##
##   Solo   `go_online()` keeps one lobby socket for presence, polled by a 10 Hz timer (no per-frame work) and reconnected after a drop. Tests without it open no socket.
##   Host   `host_session()` -> lobby `create` -> DmRelayPeer.host -> DmSession.swap_transport(relay): the world, the body and the fight stay; a guest comes in through the session's hello.
##   Guest  `join_*()` -> lobby `join` -> `join_ready(lobby, info)`: the shell starts a guest DmNextGame (`opts.lobby`) on that socket (README "Co-op on the core", "Joining").
##
## Everything a panel shows comes from `view()` (the contract of DmPartyPane); `changed` fires on any change. Errors are one place (`ERROR_TEXT`, `CLOSE_TEXT`).
## The friends list itself is DmNextFriends (the backend's friends routes, the Social window's Friends tab); a friendship it changes is announced through the lobby here (`friends_changed`).

signal changed
signal notice(text: String, kind: String)                         ## a toast for the HUD ("good" / "err" / "")
signal join_ready(lobby: DmLobbyClient, info: Dictionary)         ## solo game: we hold a seat in someone's session; the shell swaps the game for a guest game
signal client_ended(reason: String, text: String)                 ## guest game: the session is over (text "" = we left on purpose)
signal hosting_changed(on: bool)
signal social_notice(text: String)                                ## a friend invited / asked / answered: a toast that opens the Social window
signal friends_list_changed                                       ## the lobby says a friendship changed: reload the friends list

const SOLO := &"solo"
const HOST := &"host"
const CLIENT := &"client"
const HANDOFF := &"handoff"       ## joined; the solo game is being swapped for the guest game

const LIST_EVERY := 10.0
const POLL_EVERY := 0.1            ## the solo lobby link's poll (a hosted / joined session's socket is polled by its DmRelayPeer)
const PRESENCE_EVERY := 30.0       ## presence is re-checked this often (and on every area change); unchanged presence is not sent
const RECONNECT_S := [5.0, 15.0, 60.0, 120.0]
const OFFER_S := 300.0             ## an invite or ask to join is shown this long (the lobby honours it as long)
const NAME_MAX := 32
const MAX_LEVEL := 100             ## a guest's claimed level is clamped (it only decides what ITS body can cast on the host)
const CHAT_MAX := 200               ## characters in one chat line
const CHAT_PER_S := 4               ## host: chat lines and announcements a peer may send in one second

const ERROR_TEXT := {
	"full": "That session is full (4 of 4 players). Try another one, or ask the host to make room.",
	"bad_code": "That party is invite only (or the code is wrong). Ask a friend in it to invite you, from Social (O).",
	"closed": "The host is not taking new players right now.",
	"not_found": "That session no longer exists. Refresh the list.",
	"rate_limit": "Too many wrong codes. Wait a few minutes before trying again.",
	"in_session": "You are already in a session. Leave it first.",
	"not_in_session": "You are not in a session.",
	"not_host": "Only the host can do that.",
	"busy": "The lobby is full right now. Try again in a minute.",
	"bad_request": "The lobby could not use that. Give the session a name (1 to 32 letters) and try again.",
	"auth": "The lobby did not accept your login. Sign in again.",
}
## Friends' requests (invite / ask / answer) refused by the lobby, by code.
const SOCIAL_ERROR_TEXT := {
	"not_friend": "They are not online right now, or not on your friends list.",
	"not_host": "Only the party's host can invite. Ask them, or host your own party.",
	"already_in": "They are already in your party.",
	"in_session": "Leave your party first.",
	"rate_limit": "You just asked them. Give them a moment.",
	"not_found": "That request is gone: they went offline or asked someone else.",
}
const CLOSE_TEXT := {
	"host_left": "The host ended the session.",
	"kicked": "The host removed you from the session.",
	"idle": "The session timed out after a quiet stretch.",
	"shutdown": "The lobby is restarting. Try again in a moment.",
	"left": "",
}

var shell: DmNextGame
var mode: StringName = SOLO
var lobby: DmLobbyClient
var link := "off"                        ## off | connecting | ready | failed
var sessions: Array = []                 ## the last public list: [{id, name, host, area, players, max, open}]
var listed := false
var code := ""                           ## our private session's code (host)
var info: Dictionary = {}                ## the session we are in
var busy := ""                           ## "listing" | "creating" | "joining"
var last_error: Dictionary = {}          ## {code, text}
var watching := false
var levels: Dictionary = {}              ## every peer: peer id -> that hero's level (the host's table, sent on a join and a leave)
var online := false                      ## go_online() was called: keep the link (and reconnect it)
var friends_online: Dictionary = {}      ## account id -> presence {accountId, username, class, level, area, session: {id, private, open, players, max, host, isHost} | null}
var invites: Array = []                  ## [{from_id, from, info, at}] parties we were invited to
var requests: Array = []                 ## [{account_id, user, via, at}] friends asking to join us
var _nudges: Array = []                  ## friends_changed ids waiting for the link

var _relay: DmRelayPeer
var _pending: Callable = Callable()
var _list_t := 0.0
var _leaving := false
var _url := ""
var _profile_sent := false
var _members: Dictionary = {}            ## host: peer id -> the rewards member's key (its character id; -peer for one that cannot be credited)
var backend_session := ""                ## guest: the host's backend party session (for our own session_join)
var chat_log: Array[String] = []         ## the party chat's last 40 lines, as shown
var _chat_rate: Dictionary = {}          ## host: peer id -> [second, count]
var _guest_meals: Dictionary = {}        ## host: peer -> {until (its body clock ms), rate (hp a second)} of a guest's meal (guest_use)
var _build_asked := {}                   ## host: peer -> when it last asked us to re-read its build (ms)
var _after_host: Array = []              ## Callables to run once our new session exists (invite a friend, accept an ask)
var _poll_timer: Timer
var _presence_t := 0.0
var _sent_presence: Array = []
var _reconnect_n := 0
var _reconnect_at := 0.0


func setup(shell_: DmNextGame) -> void:
	shell = shell_
	set_process(false)
	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_EVERY
	_poll_timer.timeout.connect(func() -> void: _tick(POLL_EVERY))
	add_child(_poll_timer)
	shell.area_changed.connect(func(_id: String) -> void: send_presence())
	shell.session.session_ended.connect(_on_session_ended)
	shell.session.player_left.connect(_on_player_left)
	shell.session.player_joined.connect(func(_id: int) -> void: changed.emit())
	shell.session.player_left.connect(func(_id: int) -> void: changed.emit())


# ---- availability ---------------------------------------------------------------------------------------------------------------------

## "" when the lobby can be used, else why not (shown in the panel instead of the controls).
func unavailable() -> String:
	if in_party():
		return ""   # already seated: the party view must show whatever the login looks like
	if lobby_url() == "":
		return "No lobby is configured."
	if not DmConfig.allows_lobby_url(lobby_url()):
		return "This build plays on the test lobby only."
	if shell.is_offline and not overridden():
		return "Online play needs an online account. Offline characters stay on this device."
	if shell.api == null or _token().is_empty():
		return "Sign in to an online account to play with others."
	return ""


## Tests and the local trial point the lobby at a process on this machine: opts `lobby_url` / `lobby_token`, or the launch arg `--lobby=<ws url>` with the token in the
## environment (`DM_LOBBY_TOKEN`). DmConfig.allows_lobby_url accepts the test lobby and loopback addresses only, so an override can never reach the live lobby. An override also
## lets an offline character use it (a local lobby), so it is never the default path.
func overridden() -> bool:
	return String(shell.opts.get("lobby_url", "")) != "" or _arg_url() != ""


static func _arg_url() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--lobby="):
			return a.substr(8)
	return ""


func lobby_url() -> String:
	if _url != "":
		return _url
	_url = String(shell.opts.get("lobby_url", ""))
	if _url == "":
		_url = _arg_url()
	if _url == "":
		_url = DmConfig.LOBBY_URL
	return _url


func _token() -> String:
	var t := String(shell.opts.get("lobby_token", ""))
	if t == "" and overridden():
		t = OS.get_environment("DM_LOBBY_TOKEN")
	if t == "" and shell.api != null:
		t = String(shell.api.get_token())
	return t if not t.begins_with("offline:") else ""


## The launch arguments of a trial without a panel (the Social window is the panels item): `--host-party[=name]` makes a Closed party as soon as the world is up, `--join-party=<code>`
## joins one by its code before the game is built. Both need the lobby (`--lobby=<ws url>` for a local one, the test lobby otherwise).
static func arg(name: String) -> Variant:
	for a in OS.get_cmdline_user_args():
		if a == name:
			return ""
		if a.begins_with(name + "="):
			return a.substr(name.length() + 1)
	return null


## A guest that starts by itself (a launch argument, a shell without the panels): connect to the lobby and take the seat `how` names ({code} or {id}) without leaving the game
## scene that is being built. Returns the seated lobby socket (the guest game starts on it) or null (`last_error` has the words).
func seat(how: Dictionary) -> DmLobbyClient:
	var why := unavailable()
	if why != "":
		_fail("unavailable", why)
		return null
	var l := DmLobbyClient.new()
	var state := [""]
	l.authenticated.connect(func(_i: int, _n: String) -> void: state[0] = "auth")
	l.connection_failed.connect(func(r: String) -> void: state[0] = "failed:" + r)
	l.lobby_error.connect(func(c: String, m: String, _r: String) -> void: state[0] = "error:" + (c if ERROR_TEXT.has(c) else m))
	l.session_joined.connect(func(_i: Dictionary, _p: int) -> void: state[0] = "joined")
	if l.connect_to_lobby(lobby_url(), _token()) != OK:
		_fail("connect", "Could not reach the lobby. Check your connection and try again.")
		return null
	var t0 := Time.get_ticks_msec()
	while state[0] == "" and Time.get_ticks_msec() - t0 < 10000:
		l.poll()
		await get_tree().process_frame
	if state[0] != "auth":
		l.close()
		_fail("connect", _connection_text(String(state[0])))
		return null
	if how.has("code"):
		l.join_by_code(String(how["code"]))
	else:
		l.join_session(String(how.get("id", "")))
	state[0] = ""
	t0 = Time.get_ticks_msec()
	while state[0] == "" and Time.get_ticks_msec() - t0 < 10000:
		l.poll()
		await get_tree().process_frame
	if state[0] != "joined":
		var c: String = String(state[0]).trim_prefix("error:")
		l.close()
		_fail(c, String(ERROR_TEXT.get(c, "The lobby refused that (%s)." % c)) if state[0] != "" else "The lobby did not answer. Try again.")
		return null
	return l


func is_hosting() -> bool:
	return mode == HOST


func in_party() -> bool:
	return mode == HOST or mode == CLIENT


# ---- the panel's feed -----------------------------------------------------------------------------------------------------------------

func view() -> Dictionary:
	return {"unavailable": unavailable(), "link": link, "mode": String(mode), "busy": busy, "sessions": sessions, "listed": listed, "code": code,
		"info": info, "error": last_error, "roster": _roster_view(), "open": bool(info.get("open", true)), "closed": bool(info.get("private", false)), "max": DmSession.MAX_PLAYERS,
		"username": lobby.username if lobby != null else "", "area": shell.area_id, "default_name": default_name()}


func _roster_view() -> Array:
	var out: Array = []
	if mode != HOST and mode != CLIENT:
		return out
	var me := shell.session.get_my_id()
	for r in shell.session.get_roster():
		var id := int(r["peer_id"])
		out.append({"peer_id": id, "name": String(r["name"]), "discipline": String(r["discipline"]), "host": id == 1, "you": id == me,
			"can_kick": mode == HOST and id != 1})
	return out


func set_watching(on: bool) -> void:
	watching = on
	if on:
		if unavailable() == "" and mode == SOLO:
			_ensure_link(Callable(self, "_do_list"))
	elif mode == SOLO and busy == "" and not online:
		close_link()


## A real player's world (after loading): keep a lobby link for friends' presence, invites and asks. No-op when the lobby cannot be used.
func go_online() -> void:
	if unavailable() != "" or online:
		return
	online = true
	if mode == SOLO:
		_ensure_link(Callable())


func refresh() -> void:
	if unavailable() == "" and mode == SOLO:
		_ensure_link(Callable(self, "_do_list"))


func _do_list() -> void:
	busy = "listing" if not listed else busy
	lobby.request_list()
	changed.emit()


# ---- the lobby link ---------------------------------------------------------------------------------------------------------------------

func _ensure_link(then: Callable) -> void:
	if lobby != null and link == "ready" and lobby.is_open():
		if then.is_valid():
			then.call()
		return
	if lobby != null and link == "connecting":
		_pending = then
		return
	close_link()
	_pending = then
	lobby = DmLobbyClient.new()
	_wire_social(lobby)
	lobby.authenticated.connect(_on_authenticated)
	lobby.connection_failed.connect(_on_connection_failed)
	lobby.sessions_listed.connect(_on_listed)
	lobby.session_created.connect(_on_created)
	lobby.session_joined.connect(_on_joined)
	lobby.session_updated.connect(_on_updated)
	lobby.session_closed.connect(_on_lobby_session_closed)
	lobby.lobby_error.connect(_on_lobby_error)
	lobby.disconnected.connect(_on_lobby_disconnected)
	var err := lobby.connect_to_lobby(lobby_url(), _token())
	if err != OK:
		_fail("connect", "Could not reach the lobby. Check your connection and try again.")
		lobby = null
		return
	link = "connecting"
	_poll_timer.start()
	changed.emit()


func _exit_tree() -> void:
	if lobby != null and mode != HANDOFF:   # a handed-off socket belongs to the guest game now
		lobby.close()


func close_link() -> void:
	if lobby != null:
		lobby.close()
	lobby = null
	link = "off"
	_pending = Callable()
	_poll_timer.stop()
	if not friends_online.is_empty():
		friends_online.clear()
		changed.emit()


## The solo link's 10 Hz timer: poll the socket, refresh the public list while the panel is open, re-check presence, reconnect after a drop.
func _tick(dt: float) -> void:
	if lobby == null:
		if online and mode == SOLO and _reconnect_at > 0.0:
			_reconnect_at -= dt
			if _reconnect_at <= 0.0:
				_reconnect_at = 0.0
				_ensure_link(Callable())
		else:
			_poll_timer.stop()
		return
	lobby.poll()
	if link != "ready" or mode != SOLO:
		return
	if watching and busy == "":
		_list_t += dt
		if _list_t >= LIST_EVERY:
			_list_t = 0.0
			lobby.request_list()
	_presence_t += dt
	if _presence_t >= PRESENCE_EVERY:
		_presence_t = 0.0
		send_presence()
		_expire_offers()


func _on_authenticated(_id: int, _name: String) -> void:
	link = "ready"
	_list_t = 0.0
	_reconnect_n = 0
	_sent_presence = []
	send_presence()
	for id in _nudges:
		lobby.send_friends_changed(int(id))
	_nudges.clear()
	var p := _pending
	_pending = Callable()
	if p.is_valid():
		p.call()
	elif watching and mode == SOLO:
		_do_list()
	changed.emit()


func _on_connection_failed(reason: String) -> void:
	link = "failed"
	busy = ""
	var quiet := _pending_is_quiet()
	_pending = Callable()
	lobby = null
	if online and quiet:
		_schedule_reconnect(reason)   # the background link: no error toast, try again later
		changed.emit()
		return
	_fail("connect", _connection_text(reason))
	_schedule_reconnect(reason)


## True while nothing the player asked for is waiting on the link (only the background presence link was connecting).
func _pending_is_quiet() -> bool:
	return busy == "" and not watching and _after_host.is_empty()


func _schedule_reconnect(reason: String) -> void:
	if not online or reason.contains("4401") or reason.contains("4402") or reason.contains("4403") or reason.contains("replaced") or reason.contains("auth"):
		return
	_reconnect_at = float(RECONNECT_S[mini(_reconnect_n, RECONNECT_S.size() - 1)])
	_reconnect_n += 1
	_poll_timer.start()


static func _connection_text(reason: String) -> String:
	if reason.contains("4401") or reason.contains("auth"):
		return "The lobby did not accept your login. Sign in again."
	if reason.contains("4402") or reason.contains("replaced"):
		return "This account was opened somewhere else, which closed this lobby link."
	if reason.contains("4429") or reason.contains("rate"):
		return "You were sending too fast. Wait a moment and try again."
	return "Could not reach the lobby. Check your connection and try again."


func _on_lobby_disconnected(reason: String) -> void:
	link = "off"
	lobby = null
	friends_online.clear()
	if mode == HOST:
		_stop_hosting("Lost the connection to the lobby. You are playing solo again.", "err")
	elif mode == SOLO:
		busy = ""
		if watching:
			_fail("connect", _connection_text(reason))
	_schedule_reconnect(reason)
	changed.emit()


func _on_listed(list: Array) -> void:
	sessions = list
	listed = true
	if busy == "listing":
		busy = ""
	last_error = {} if last_error.get("code", "") == "connect" else last_error
	changed.emit()


func _on_lobby_error(c: String, msg: String, req: String) -> void:
	if req in ["invite", "ask", "answer", "set_private"]:
		_fail(c, String(SOCIAL_ERROR_TEXT.get(c, ERROR_TEXT.get(c, msg))))
		return
	busy = "" if busy != "listing" else busy
	_fail(c, String(ERROR_TEXT.get(c, msg if msg != "" else "The lobby refused that (%s)." % c)))


func _fail(c: String, text: String) -> void:
	last_error = {"code": c, "text": text}
	notice.emit(text, "err")
	changed.emit()


# ---- hosting ------------------------------------------------------------------------------------------------------------------------------

## Turn this solo session into a hosted one. Closed (is_private) parties are invite only; Open ones show in everyone's list.
func host_session(session_name: String, is_private: bool = false) -> void:
	var why := unavailable()
	if why != "":
		_fail("unavailable", why)
		return
	if mode != SOLO:
		_fail("in_session", String(ERROR_TEXT["in_session"]))
		return
	if busy == "creating" or busy == "joining":
		return
	var nm := clean_name(session_name)
	if nm == "":
		nm = default_name()
	last_error = {}
	busy = "creating"
	changed.emit()
	_ensure_link(func() -> void: lobby.create_session(nm, shell.area_id, is_private, "", world()))


## Host: our world as members and friends see it (DECISIONS B26): our difficulty. No heat: Ascension is not in the rebuild (B36), so it is always 0.
func world() -> Dictionary:
	return {"heat": 0, "difficulty": shell.meta.difficulty if shell.meta != null else "medium"}


## Host: our difficulty changed (DmNextMeta.set_difficulty): tell the lobby, which tells members, friends and the list.
func sync_world() -> void:
	if mode != HOST or lobby == null or link != "ready":
		return
	var w := world()
	if int(info.get("heat", -1)) == int(w["heat"]) and String(info.get("difficulty", "")) == String(w["difficulty"]):
		return
	info["heat"] = int(w["heat"])
	info["difficulty"] = String(w["difficulty"])
	lobby.set_world(int(w["heat"]), String(w["difficulty"]))
	changed.emit()


func default_name() -> String:
	var who := String(shell.opts.get("name", "")) if String(shell.opts.get("name", "")) != "" else "Hero"
	return clean_name("%s's crypt" % who)


static func clean_name(s: String) -> String:
	var out := ""
	for ch in s.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			out += ch
	return out.substr(0, NAME_MAX).strip_edges()


func _on_created(i: Dictionary, c: String) -> void:
	if busy != "creating" or mode != SOLO:
		return
	busy = ""
	lobby.relay = checked_relay(lobby.relay)
	_relay = DmRelayPeer.new()
	if _relay.host(lobby) != OK or shell.session.swap_transport(_relay) != OK:
		lobby.leave()
		_relay = null
		_fail("unavailable", "Could not start the session. Try again.")
		return
	info = i
	code = c
	mode = HOST
	last_error = {}
	_poll_timer.stop()   # the relay peer polls the socket now
	if shell.rewards != null:
		shell.rewards.local_peer_id = 1
	notice.emit("Hosting \"%s\" (%s)" % [String(i.get("name", "")), "Closed: invite friends" if bool(i.get("private", false)) else "Open: anyone can join"], "good")
	hosting_changed.emit(true)
	var after := _after_host
	_after_host = []
	for f in after:
		(f as Callable).call()
	changed.emit()


## The relay the lobby offers, kept only when it is the test relay (or on this machine): the rebuilt client never talks to the live relay (DECISIONS B38). {} makes the
## relay peer stay on the lobby's WebSocket, which is the test lobby's.
static func checked_relay(r: Dictionary) -> Dictionary:
	if r.is_empty() or DmConfig.allows_relay(String(r.get("addr", "")), int(r.get("port", 0))):
		return r
	printerr("[coop] the lobby offered a relay this build does not use (port %d): staying on the lobby's WebSocket" % int(r.get("port", 0)))
	return {}


func _on_updated(i: Dictionary) -> void:
	info = i
	changed.emit()


## Host: let new players in (true) or keep the session as it is (false; it also leaves the public list).
func set_open(open: bool) -> void:
	if mode != HOST or _relay == null:
		return
	_relay.refuse_new_connections = not open


## Host: Closed (invite only, out of the public list; friends can ask) or Open (listed, anyone joins).
func set_closed(closed: bool) -> void:
	if mode == HOST and lobby != null:
		lobby.set_private(closed)


## Host: remove a player.
func kick(peer_id: int) -> void:
	if mode == HOST:
		shell.session.kick(peer_id)


func _on_lobby_session_closed(reason: String) -> void:
	if mode == HOST:
		_stop_hosting(String(CLOSE_TEXT.get(reason, "The session closed.")) + " You are playing solo again.", "err")
	elif mode == SOLO and busy != "" and busy != "creating":   # (the close of a party we just ended can land while the next one is created)
		busy = ""
		changed.emit()


## Host: back to a solo game (the world and the body stay): the guests are dropped, the relay session is closed.
func _stop_hosting(text: String, kind: String) -> void:
	if mode != HOST:
		return
	mode = SOLO
	info = {}
	code = ""
	_members.clear()
	shell.session.swap_transport(OfflineMultiplayerPeer.new())
	_relay = null
	if shell.rewards != null:
		for cid in shell.rewards.members.keys():
			if (shell.rewards.members[cid] as DmRewardsMember).remote:
				shell.rewards.remove_member(int(cid))
	if text != "":
		notice.emit(text, kind)
	hosting_changed.emit(false)
	if lobby != null and lobby.is_open():
		_poll_timer.start()
	if not watching and not online:
		close_link()
	changed.emit()


# ---- joining ----------------------------------------------------------------------------------------------------------------------------

func join_session(session_id: String, session_code: String = "") -> void:
	if not _can_join():
		return
	busy = "joining"
	last_error = {}
	changed.emit()
	_ensure_link(func() -> void: lobby.join_session(session_id, session_code))


## Join a Closed party by its code (the host's `code`).
func join_by_code(session_code: String) -> void:
	var c := session_code.strip_edges()
	if c == "":
		_fail("bad_code", String(ERROR_TEXT["bad_code"]))
		return
	if not _can_join():
		return
	busy = "joining"
	last_error = {}
	changed.emit()
	_ensure_link(func() -> void: lobby.join_by_code(c))


func _can_join() -> bool:
	var why := unavailable()
	if why != "":
		_fail("unavailable", why)
		return false
	if mode != SOLO:
		_fail("in_session", String(ERROR_TEXT["in_session"]))
		return false
	return busy != "creating" and busy != "joining"


func _on_joined(i: Dictionary, _peer: int) -> void:
	if busy != "joining" or mode != SOLO:
		return
	busy = ""
	info = i
	mode = HANDOFF
	lobby.relay = checked_relay(lobby.relay)
	printerr("[coop] guest: seated in \"%s\" as peer %d, swapping in the guest game" % [String(i.get("name", "")), _peer])
	changed.emit()
	join_ready.emit(lobby, i)


## Guest game: take over the lobby socket the join happened on (the DmRelayPeer already tunnels through it).
func adopt_client(lobby_: DmLobbyClient, relay: DmRelayPeer) -> void:
	lobby = lobby_
	lobby.relay = checked_relay(lobby.relay)
	_relay = relay
	link = "ready"
	mode = CLIENT
	info = lobby.session
	online = true
	_wire_social(lobby)
	lobby.world_changed.connect(_on_world_changed)
	send_presence()


## A member: the host's world changed (DECISIONS B26); the lobby's session already holds it.
func _on_world_changed(_heat: int, _difficulty: String) -> void:
	info = lobby.session
	changed.emit()


# ---- leaving / the session ends --------------------------------------------------------------------------------------------------

## The panel's Leave: a host stops hosting (the game goes on solo), a guest goes back to its own world.
func leave() -> void:
	if mode == HOST:
		_stop_hosting("You closed the session.", "")
	elif mode == CLIENT:
		_leaving = true
		shell.session.leave()


func _on_session_ended(reason: String) -> void:
	if mode != CLIENT:
		return
	var rc := _relay.close_reason if _relay != null else ""
	var why := ""
	if _leaving:
		why = ""
	elif CLOSE_TEXT.has(rc):
		why = String(CLOSE_TEXT[rc])
	elif rc.begins_with("connection lost") or reason.begins_with("lost connection"):
		why = "Lost the connection to the host. You are back in your own world."
	elif reason == "host closed the session":
		why = String(CLOSE_TEXT["host_left"])
	else:
		why = reason.substr(0, 1).to_upper() + reason.substr(1) + "."   # the host's own refusal text (full, version mismatch, handshake)
	mode = SOLO
	info = {}
	_leaving = false
	client_ended.emit(rc if rc != "" else reason, why)
	changed.emit()


func _on_player_left(id: int) -> void:
	if not shell.session.is_host() or not _members.has(id):
		return
	var key: int = _members[id]
	_members.erase(id)
	_guest_meals.erase(id)
	_chat_rate.erase(id)
	if shell.rewards != null and shell.rewards.members.has(key):
		shell.rewards.remove_member(key)
	changed.emit()


# ---- the host <-> guest handshake: the guest's own account (DECISIONS B22) ----------------------------------------------------------

## Host (called once the rewards exist): a guest's rewards and loot follow the party's events.
func attach_host() -> void:
	shell.rewards.member_credited.connect(_on_credited)
	shell.rewards.loot_dropped.connect(_on_loot_dropped)
	shell.rewards.drop_event_for.connect(_on_drop_event)


## Guest: once the session is live, tell the host who we are. The host binds that character to our body (what ITS caster may cast follows the level) and makes it a
## rewards member, credited on OUR backend account once we joined its party session with our own token.
func send_profile() -> void:
	if _profile_sent or shell.session.is_host() or not shell.session.is_active():
		return
	_profile_sent = true
	var ch := shell.character
	_rpc_profile.rpc_id(1, {"character_id": int(ch.get("id", 0)), "class_index": int(ch.get("class_index", 0)), "level": int(ch.get("level", 1)),
		"experience": int(ch.get("experience", 0)), "rolls_drops": true})


@rpc("any_peer", "call_remote", "reliable")
func _rpc_profile(p: Dictionary) -> void:
	if not multiplayer.is_server() or shell == null or shell.rewards == null:
		return
	var peer := multiplayer.get_remote_sender_id()
	var body := shell.body_of(peer)
	if body == null or _members.has(peer):
		return
	var cid := int(p.get("character_id", 0))
	var ci := clampi(int(p.get("class_index", 0)), 0, 99)
	var lvl := clampi(int(p.get("level", 1)), 1, MAX_LEVEL)
	body.bind_character({"id": cid, "class_index": ci, "level": lvl})
	var key := cid if cid > 0 and not shell.rewards.members.has(cid) else -peer   # a clashing id (two test backends) gets a private key: never credited
	var d := DmCharacterBuild.discipline_for(float(ci))
	var m := DmRewardsMember.make(key, peer, body, null, lvl, {"id": d["id"], "family": d["family"]})
	m.remote = true
	m.rolls_own_drops = p.get("rolls_drops") == true   # its client rolls its drops from its own tape (DECISIONS B20)
	m.prog.character["experience"] = maxi(0, int(p.get("experience", 0)))
	m.trophy_store = func(_boss: String) -> bool: return false   # a guest's first-kill trophies are its own backend's business (later)
	m.blocked = "pending_join" if key > 0 else "no_character"
	shell.rewards.add_member(m)
	_members[peer] = key
	sync_levels()
	_rpc_welcome.rpc_id(peer, shell.rewards.session_id)
	changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_welcome(session_id: String) -> void:
	backend_session = session_id
	if shell.joiner != null:
		shell.joiner.begin_backend(session_id)
	changed.emit()


## Guest -> host: "I joined the backend session with my own account" (ok) or why not. The host starts crediting this member on ok.
func report_backend(ok: bool, why: String) -> void:
	if not shell.session.is_host() and shell.session.is_active():
		_rpc_backend.rpc_id(1, ok, why)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_backend(ok: bool, why: String) -> void:
	if not multiplayer.is_server() or shell == null or shell.rewards == null:
		return
	var peer := multiplayer.get_remote_sender_id()
	var key: int = _members.get(peer, 0)
	var m: DmRewardsMember = shell.rewards.members.get(key)
	if m == null or key <= 0:
		return
	if ok:
		m.blocked = ""
		m.joined = true
		fetch_build(peer)   # its gear, set bonuses, boons, vows and level from the server, not from its client
	else:
		m.blocked = "join_refused"
		shell.rewards.member_refused.emit(key, "join_refused: " + why)
	changed.emit()


## Host: build a member's hero from the server's record of it (DmNextGame.remote_builds), then refresh its body and caster. Called when its backend
## join succeeds and whenever its client says what it wears changed.
func fetch_build(peer: int) -> void:
	var key: int = _members.get(peer, 0)
	if key <= 0 or shell.rewards == null or shell.rewards.session_id == "" or shell.api == null:
		return
	var r: DmResult = await shell.api.session_member_build(shell.rewards.session_id, key)
	if not r.ok or not (r.data is Dictionary) or not _members.has(peer):
		return
	shell.remote_builds[peer] = {"character": r.data["character"], "slots": r.data.get("slots", []), "local": r.data.get("local", {})}
	var b := shell.body_of(peer)
	if b == null or not is_instance_valid(b):
		return
	b.character["level"] = maxi(int(b.character.get("level", 1)), int(r.data["character"].get("level", 1)))   # the real level, past the profile clamp
	var m: DmRewardsMember = shell.rewards.members.get(key)
	if m != null:
		m.prog.character["level"] = int(b.character["level"])
	var build := shell.build_for(peer)
	b.refresh_stats(build)
	var c := b.get_node_or_null("Rites") as DmRiteCaster
	if c != null:
		c.refresh_stats(build)
		c.set_runes(shell.rune_sockets(peer))   # its socketed runes reach its rites (the server's record)
	sync_levels()


## Guest: we drank `id` from our own bag (DmNextBelt.remote_use; the bag already paid): the host applies it to our hero, which it simulates.
func guest_use(id: String) -> void:
	if not shell.session.is_host() and shell.session.is_active():
		_rpc_guest_use.rpc_id(1, id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_guest_use(id: String) -> void:
	if not multiplayer.is_server() or shell == null:
		return
	var peer := multiplayer.get_remote_sender_id()
	var b := shell.body_of(peer)
	if b == null or not is_instance_valid(b) or not b.alive or b.p.is_empty():
		return
	var meal: Variant = DmBrews.meal(id)
	if meal != null:
		_guest_meals[peer] = {"until": b.clock_ms() + float(meal["seconds"]) * 1000.0, "rate": b.max_hp * float(meal["healFrac"]) / float(meal["seconds"])}
	elif DmContent.brews().has(id):
		b.apply_brew(id)
		var rites := b.get_node_or_null("Rites") as DmRiteCaster
		if rites != null and not rites.shares_vitals():
			rites.apply_brew(id)
	elif DmContent.healing_flasks().has(id):
		b.heal(b.max_hp * float(DmContent.healing_flasks()[id]))


## Host: a guest's meal heals its hero over the meal's seconds (DmNextBelt.tick does the same for the host's own hero).
func _physics_process(dt: float) -> void:
	if _guest_meals.is_empty():
		return
	for peer in _guest_meals.keys():
		var b := shell.body_of(int(peer)) if shell != null else null
		var meal: Dictionary = _guest_meals[peer]
		if b == null or not is_instance_valid(b) or not b.alive or b.clock_ms() >= float(meal["until"]):
			_guest_meals.erase(peer)
		else:
			b.heal(float(meal["rate"]) * dt)


## Guest: what we wear changed (gear, belt, kit, rune sockets): the host reads our build from the server again.
func build_changed() -> void:
	if mode != CLIENT or not shell.session.is_active():
		return
	_rpc_build_changed.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_build_changed() -> void:
	if multiplayer.is_server() and shell != null:
		var peer := multiplayer.get_remote_sender_id()
		var now := Time.get_ticks_msec()
		if now - int(_build_asked.get(peer, 0)) < 1000:   # at most once a second per member
			return
		_build_asked[peer] = now
		fetch_build(peer)


## Host: an accepted report credited a member. Our own level-up reaches the party frames; a guest's credit goes to its client (its own progression applies it),
## and its body fights at its new level here.
func _on_credited(cid: int, delta: Dictionary) -> void:
	var m: DmRewardsMember = shell.rewards.members.get(cid)
	if m == null:
		return
	if not m.remote:
		if int(delta.get("levels", 0)) > 0:
			sync_levels()   # the host levelled: every guest's party frame shows it
			send_presence()
		return
	if int(delta.get("levels", 0)) > 0 and m.body != null and is_instance_valid(m.body):
		var b := m.body as DmHeroBody
		b.character["level"] = int(m.prog.character["level"])
		b.refresh_stats(shell.build_for(m.peer_id))
		b.restore_vitals()
		var c := b.get_node_or_null("Rites") as DmRiteCaster
		if c != null:
			c.refresh_stats(shell.build_for(m.peer_id))
		sync_levels()
	if _here(m.peer_id):   # a guest that left is credited by the report on its account; its client is gone
		_rpc_credit.rpc_id(m.peer_id, delta)


## Host: the peer is still connected (a member that left is removed only after its last report went out).
func _here(peer: int) -> bool:
	return multiplayer.get_peers().has(peer)


@rpc("authority", "call_remote", "reliable")
func _rpc_credit(delta: Dictionary) -> void:
	if shell.joiner != null:
		shell.joiner.on_credit(delta)


## Host: gold and shards the rewards dropped for a guest (its items are rolled on its own client: `_on_drop_event`).
func _on_loot_dropped(cid: int, drop: Dictionary, pos: Vector3) -> void:
	var m: DmRewardsMember = shell.rewards.members.get(cid)
	if m != null and m.remote and _here(m.peer_id):
		_rpc_loot.rpc_id(m.peer_id, drop, pos)


@rpc("authority", "call_remote", "reliable")
func _rpc_loot(drop: Dictionary, pos: Vector3) -> void:
	if shell.joiner != null:
		shell.joiner.on_loot(drop, pos)


## Host: a drop event a guest rolls from its own tape (DECISIONS B20).
func _on_drop_event(cid: int, kind: String, facts: Dictionary, pos: Vector3) -> void:
	var m: DmRewardsMember = shell.rewards.members.get(cid)
	if m != null and m.remote and _here(m.peer_id):
		_rpc_drop_event.rpc_id(m.peer_id, kind, facts, pos)


@rpc("authority", "call_remote", "reliable")
func _rpc_drop_event(kind: String, facts: Dictionary, pos: Vector3) -> void:
	if shell.joiner != null:
		shell.joiner.on_drop_event(kind, facts, pos)


## The level a party frame shows for a hero body: the local hero's own character, else the host's replicated table, else what the body knows.
func level_of(b: DmHeroBody) -> int:
	if b == null:
		return 1
	if b == shell.local_body():
		return int(shell.character.get("level", 1))
	return int(levels.get(b.owner_peer, b.character.get("level", 1)))


## Host: send every hero's level to every peer (event-driven: a join, a profile; never per frame). A guest's hero bodies carry no character, so this table is the only
## place a guest learns the others' levels.
func sync_levels() -> void:
	if not shell.session.is_host():
		return
	var t := {}
	for b in shell.session.get_bodies():
		var hb := b as DmHeroBody
		if hb != null:
			t[hb.owner_peer] = int(shell.character.get("level", 1)) if hb == shell.local_body() else int(hb.character.get("level", 1))
	levels = t
	if shell.session.is_active() and not multiplayer.get_peers().is_empty():
		for peer in shell.net.guests():
			_rpc_levels.rpc_id(peer, t)
		changed.emit()


## Host: the party plays in the host's world, so a guest's seals, doors and open areas are the host's (the world's `unlocked`; what a guest's own account has broken is its own
## business in its own world). Told to a guest as it joins (`to` = its peer id: the doors just stand open for it, silently) and to every guest whenever the host's seals change.
func send_seals(to := 0) -> void:
	if not shell.session.is_host() or not shell.session.is_active():
		return
	var open: Array = shell.world.unlocked.keys()
	if to != 0:
		_rpc_seals.rpc_id(to, open, true)
		return
	for peer in shell.net.guests():
		_rpc_seals.rpc_id(peer, open, false)


## Guest: the host's seals. A seal that breaks while we are in the party opens its door in front of us (the world's `door_opened`: the gate sound) and says so on the banner the host
## sees; the state we are given on joining sets the doors without either.
@rpc("authority", "call_remote", "reliable")
func _rpc_seals(open: Array, joining: bool) -> void:
	var w := shell.world
	var was: Dictionary = w.unlocked.duplicate()
	w.set_unlocked(open, joining)
	if joining or shell.chapterhouse == null:
		return
	for id: String in w.unlocked:
		if not was.has(id):
			shell.chapterhouse.announce_seal(id)


@rpc("authority", "call_remote", "reliable")
func _rpc_levels(t: Dictionary) -> void:
	levels = t
	changed.emit()


# ---- waystones and the recall for a guest: the host moves its body (the host simulates every body) ---------------------------------------

## A guest beside a waystone (or in the Chapterhouse) asks the host to take it to `area`; `recall` = the T recall home (the guest stood still for it).
func ask_travel(area: String, recall := false) -> void:
	if in_party() and shell.session.is_active() and not shell.session.is_host():
		_rpc_travel.rpc_id(1, area, recall)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_travel(area: String, recall: bool) -> void:
	if not multiplayer.is_server() or shell == null or shell.chapterhouse == null:
		return
	var peer := multiplayer.get_remote_sender_id()
	var b: DmHeroBody = shell.body_of(peer)
	if b == null or not b.alive:
		return
	var to: Variant = shell.chapterhouse.guest_destination(b, area, recall)
	if to is String:
		_rpc_travel_refused.rpc_id(peer, to)
		return
	var from := b.position
	shell.chapterhouse.move_body(b, (to as Vector3).x, (to as Vector3).z)
	_rpc_travelled.rpc_id(peer, "chapterhouse" if recall else area, from, to)


@rpc("authority", "call_remote", "reliable")
func _rpc_travelled(area: String, from: Vector3, to: Vector3) -> void:
	if shell != null and shell.chapterhouse != null:
		shell.chapterhouse.arrived(area, from, to)


@rpc("authority", "call_remote", "reliable")
func _rpc_travel_refused(why: String) -> void:
	if shell != null and shell.chapterhouse != null:
		shell.chapterhouse.travel_refused(why)


# ---- ground drops between members (ground.cjs): the Reliquary's Drop, drawn for the members the server lets take it -----------------------

## A member dropped gear on the party session's ground (DmNextUiHost.drop_gear): every member the server says may take it draws it.
func share_ground(entry: Dictionary) -> void:
	if not in_party() or not shell.session.is_active():
		return
	if shell.session.is_host():
		_broadcast_ground(1, entry)
	else:
		_rpc_ground.rpc_id(1, entry)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_ground(entry: Dictionary) -> void:
	if multiplayer.is_server() and shell != null and shell.rewards != null and entry.get("drop_id") is String and entry.get("eligible") is Array:
		_broadcast_ground(multiplayer.get_remote_sender_id(), entry)


func _broadcast_ground(from_peer: int, entry: Dictionary) -> void:
	for m: DmRewardsMember in shell.rewards.members.values():
		if m.peer_id == from_peer or not (entry["eligible"] as Array).has(m.character_id):
			continue
		if m.peer_id == multiplayer.get_unique_id():
			_show_ground(entry)
		elif _here(m.peer_id):
			_rpc_ground_show.rpc_id(m.peer_id, entry)


@rpc("authority", "call_remote", "reliable")
func _rpc_ground_show(entry: Dictionary) -> void:
	_show_ground(entry)


func _show_ground(entry: Dictionary) -> void:
	var m: DmRewardsMember = shell.my_member() if shell != null else null
	if m != null:
		m.loot_view.shared_item(entry)


func _hide_ground(drop_id: String) -> void:
	var m: DmRewardsMember = shell.my_member() if shell != null else null
	if m != null:
		m.loot_view.remove_shared(drop_id)


## Someone took a dropped piece: every other copy of it goes.
func share_taken(drop_id: String) -> void:
	if not in_party() or not shell.session.is_active():
		return
	if shell.session.is_host():
		_broadcast_taken(1, drop_id)
	else:
		_rpc_taken.rpc_id(1, drop_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_taken(drop_id: String) -> void:
	if multiplayer.is_server() and shell != null:
		_broadcast_taken(multiplayer.get_remote_sender_id(), drop_id)


func _broadcast_taken(from_peer: int, drop_id: String) -> void:
	for p in shell.net.guests():
		if p != from_peer:
			_rpc_taken_show.rpc_id(p, drop_id)
	if from_peer != 1:
		_hide_ground(drop_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_taken_show(drop_id: String) -> void:
	_hide_ground(drop_id)


# ---- party chat ---------------------------------------------------------------------------------------------------------------------------

## Returns true when the line went to the party (false = solo: the caller shows its "nobody hears you").
func chat(text: String) -> bool:
	var t := text.strip_edges().substr(0, CHAT_MAX)
	if t == "" or not in_party() or not shell.session.is_active():
		return false
	if shell.session.is_host():
		_broadcast_chat(1, t)
	else:
		_rpc_say.rpc_id(1, t)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _rpc_say(text: String) -> void:
	if not multiplayer.is_server() or shell == null:
		return
	var peer := multiplayer.get_remote_sender_id()
	if _over_rate(peer):
		return
	var t := text.strip_edges().substr(0, CHAT_MAX)
	if t != "":
		_broadcast_chat(peer, t)


## Host: more than CHAT_PER_S lines (chat + announcements) from one peer in a second are dropped.
func _over_rate(peer: int) -> bool:
	var now := int(Time.get_ticks_msec() / 1000)
	var r: Array = _chat_rate.get(peer, [now, 0])
	if int(r[0]) != now:
		r = [now, 0]
	r[1] = int(r[1]) + 1
	_chat_rate[peer] = r
	return int(r[1]) > CHAT_PER_S


func _broadcast_chat(peer: int, text: String) -> void:
	var who := ""
	for r in shell.session.get_roster():
		if int(r["peer_id"]) == peer:
			who = String(r["name"])
	for p in shell.net.guests():
		_rpc_chat.rpc_id(p, who, text)
	_show_chat(who, text)


@rpc("authority", "call_remote", "reliable")
func _rpc_chat(who: String, text: String) -> void:
	_show_chat(who, text)


## A find the whole party reads in chat (a legendary, a new rune). `line` names the finder as "{who}"; the host fills in the roster name.
## Returns false when not in a party (the caller shows its own line).
func announce(line: String) -> bool:
	var t := line.strip_edges().substr(0, CHAT_MAX)
	if t == "" or not in_party() or not shell.session.is_active():
		return false
	if shell.session.is_host():
		_broadcast_announce(1, t)
	else:
		_rpc_announce.rpc_id(1, t)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _rpc_announce(line: String) -> void:
	if not multiplayer.is_server() or shell == null:
		return
	var peer := multiplayer.get_remote_sender_id()
	if _over_rate(peer):
		return
	var t := line.strip_edges().substr(0, CHAT_MAX)
	if t != "":
		_broadcast_announce(peer, t)


func _broadcast_announce(peer: int, line: String) -> void:
	var who := "Someone"
	for r in shell.session.get_roster():
		if int(r["peer_id"]) == peer:
			who = String(r["name"])
	var text := line.replace("{who}", who)
	for p in shell.net.guests():
		_rpc_announced.rpc_id(p, text)
	_show_line(text)


@rpc("authority", "call_remote", "reliable")
func _rpc_announced(text: String) -> void:
	_show_line(text)


func _show_chat(who: String, text: String) -> void:
	_show_line("[%s] %s" % [who, text], not _is_me(who))


## True when `who` (a roster name) is this player: their own chat echoes back from the host without a ping.
func _is_me(who: String) -> bool:
	var me := multiplayer.get_unique_id()
	for r in shell.session.get_roster():
		if int(r["peer_id"]) == me:
			return String(r["name"]) == who
	return false


## `ping`: another player's chat line, which the HUD marks with a sound.
func _show_line(line: String, ping: bool = false) -> void:
	chat_log.append(line)
	if chat_log.size() > 40:
		chat_log.pop_front()
	shell.game_event("chat", {"text": line, "ping": ping})


# ---- friends over the lobby: presence, invites, asks to join (DECISIONS B18) ------------------------------------------------------------

func _wire_social(l: DmLobbyClient) -> void:
	l.friends_snapshot.connect(_on_friends_snapshot)
	l.friend_presence.connect(_on_friend_presence)
	l.friends_changed.connect(func() -> void: friends_list_changed.emit())
	l.invited.connect(_on_invited)
	l.invite_sent.connect(func(_id: int, user: String) -> void: notice.emit("Invited %s. They can join from their Social window." % user, "good"))
	l.join_requested.connect(_on_join_requested)
	l.ask_sent.connect(func(_id: int, user: String) -> void: notice.emit("Asked %s. You join as soon as they accept." % user, "good"))
	l.ask_declined.connect(func(user: String) -> void: social_notice.emit("%s cannot take you along right now." % user))


## We changed a friendship (DmNextFriends): the lobby reloads both sides' lists. Kept until the link is ready (a player can answer a request
## in the first second in the world, before the link is up).
func friends_changed(other_id: int) -> void:
	if lobby != null and link == "ready":
		lobby.send_friends_changed(other_id)
	elif online and not _nudges.has(other_id):
		_nudges.append(other_id)


## What friends see: our discipline, level and area (sent when it changed).
func send_presence() -> void:
	if lobby == null or link != "ready":
		return
	var ch := shell.character
	var p := [int(ch.get("class_index", 0)), int(ch.get("level", 1)), String(shell.area_id)]
	if p == _sent_presence:
		return
	_sent_presence = p
	lobby.send_presence(p[0], p[1], p[2])


func _on_friends_snapshot(list: Array) -> void:
	friends_online.clear()
	for p in list:
		if p is Dictionary:
			friends_online[int(p.get("accountId", 0))] = p
	changed.emit()


func _on_friend_presence(id: int, p: Dictionary) -> void:
	if p.is_empty():
		friends_online.erase(id)
	else:
		friends_online[id] = p
	changed.emit()


func _on_invited(from_name: String, from_id: int, i: Dictionary, auto: bool) -> void:
	if auto and mode == SOLO and busy == "":   # the answer to our own ask: go
		social_notice.emit("%s let you in. Joining..." % from_name)
		join_session(String(i.get("id", "")))
		return
	for v in invites:
		if int(v["from_id"]) == from_id:
			invites.erase(v)
			break
	invites.append({"from_id": from_id, "from": from_name, "info": i, "at": Time.get_ticks_msec()})
	social_notice.emit("%s invited you to their party." % from_name)
	changed.emit()


func _on_join_requested(id: int, user: String, via: String) -> void:
	for r in requests:
		if int(r["account_id"]) == id:
			requests.erase(r)
			break
	requests.append({"account_id": id, "user": user, "via": via, "at": Time.get_ticks_msec()})
	social_notice.emit(("%s (a friend of %s) asks to join you." % [user, via]) if via != "" else "%s asks to join you." % user)
	changed.emit()


func _expire_offers() -> void:
	var cut := Time.get_ticks_msec() - int(OFFER_S * 1000.0)
	var n := invites.size() + requests.size()
	invites = invites.filter(func(v: Dictionary) -> bool: return int(v["at"]) > cut)
	requests = requests.filter(func(r: Dictionary) -> bool: return int(r["at"]) > cut)
	if invites.size() + requests.size() != n:
		changed.emit()


## Invite a friend. Playing solo, this first hosts an Open party.
func invite_friend(id: int) -> void:
	if mode == CLIENT:
		_fail("not_host", String(SOCIAL_ERROR_TEXT["not_host"]))
	elif mode == HOST:
		if lobby != null:
			lobby.invite(id)
	else:
		_host_then(func() -> void: lobby.invite(id))


## Ask a friend to take us along (they are solo, or in a party that is not Open to us).
func ask_to_join(id: int) -> void:
	if mode != SOLO:
		_fail("in_session", String(SOCIAL_ERROR_TEXT["in_session"]))
		return
	_ensure_link(func() -> void: lobby.ask(id))


## Join a friend's Open party straight away.
func join_friend(id: int) -> void:
	var p: Dictionary = friends_online.get(id, {})
	var sess: Variant = p.get("session")
	if not (sess is Dictionary):
		ask_to_join(id)
		return
	join_session(String((sess as Dictionary).get("id", "")))


func accept_invite(from_id: int) -> void:
	for v in invites:
		if int(v["from_id"]) == from_id:
			invites.erase(v)
			join_session(String((v["info"] as Dictionary).get("id", "")))
			return


func decline_invite(from_id: int) -> void:
	for v in invites:
		if int(v["from_id"]) == from_id:
			invites.erase(v)
			changed.emit()
			return


## Answer a friend's ask. Accepting while solo first hosts an Open party, then lets them in.
func answer_request(id: int, accept: bool) -> void:
	for r in requests:
		if int(r["account_id"]) == id:
			requests.erase(r)
			break
	changed.emit()
	if not accept:
		if lobby != null and link == "ready":
			lobby.answer(id, false)
		return
	if mode == CLIENT:
		_fail("not_host", String(SOCIAL_ERROR_TEXT["not_host"]))
	elif mode == HOST:
		lobby.answer(id, true)
	else:
		_host_then(func() -> void: lobby.answer(id, true))


func _host_then(f: Callable) -> void:
	_after_host.append(f)
	if busy != "creating":
		host_session("", false)
	if mode != SOLO or busy != "creating":   # hosting was refused: drop the queued action
		_after_host.clear()
