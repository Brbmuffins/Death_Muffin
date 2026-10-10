class_name DmNextParty
extends Node
## Child "Party" of DmNextGame (every peer, same NodePath: its RPCs live here). The lobby side of the rebuild (REBUILD D3 / D6, owner 2026-10-07):
## a lobby of private 6-digit codes plus a public list of open sessions, hosting that turns the running solo session into a hosted one, joining
## that hands the player to the host's session, the roster / kick / open-closed controls, party chat, and the host <-> joiner handshake that
## carries a joiner's own character in (kill credit, XP and loot reach the joiner's OWN backend account, never the host's).
##
##   Solo   no lobby traffic at all (no socket, no per-frame work). The window opens a lobby socket on demand (`set_watching`) and closes it again.
##   Host   `host_session()` -> lobby `create` -> DmRelayPeer.host -> DmSession.swap_transport(relay): the world, the body and the rewards stay.
##   Client `join_*()` -> lobby `join` -> `join_ready(lobby, info)`: the shell (main.gd) swaps the solo game for a client DmNextGame on that socket.
##
## Everything the UI shows comes from `view()`; `changed` fires on any change. Errors are one place (`ERROR_TEXT`, `CLOSE_TEXT`).

signal changed
signal notice(text: String, kind: String)                         ## a toast for the HUD ("good" / "err" / "")
signal join_ready(lobby: DmLobbyClient, info: Dictionary)         ## solo game: we hold a seat in someone's session; main swaps the game
signal client_ended(reason: String, text: String)                 ## client game: the session is over (text "" = we left on purpose)
signal hosting_changed(on: bool)

const SOLO := &"solo"
const HOST := &"host"
const CLIENT := &"client"
const HANDOFF := &"handoff"       ## joined; the solo game is being swapped for the client game

const LIST_EVERY := 10.0
const NAME_MAX := 32
const CHAT_MAX := 200
const CHAT_PER_S := 4
const MAX_LEVEL := 100             ## a joiner's claimed level is clamped (it only decides what ITS body can cast on the host)

const ERROR_TEXT := {
	"full": "That session is full (4 of 4 players). Try another one, or ask the host to make room.",
	"bad_code": "That code does not match any private session. Check the six digits with your host.",
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
var backend_session := ""                ## the host's backend session id (joiner: for its own session_join)
var host_name := ""
var chat_log: Array = []                 ## last lines (tests / the window)

var _relay: DmRelayPeer
var _pending: Callable = Callable()
var _list_t := 0.0
var _leaving := false
var _members: Dictionary = {}            ## host: peer id -> the rewards member's key
var _chat_rate: Dictionary = {}          ## host: peer id -> [second, count]
var _url := ""
var _profile_sent := false


func setup(shell_: DmNextGame) -> void:
	shell = shell_
	set_process(false)
	shell.session.session_ended.connect(_on_session_ended)
	shell.session.player_left.connect(_on_player_left)
	shell.session.player_joined.connect(func(_id: int) -> void: changed.emit())
	shell.session.player_left.connect(func(_id: int) -> void: changed.emit())


# ---- availability ---------------------------------------------------------------------------------------------------------------------

## "" when the lobby can be used, else why not (shown in the window instead of the controls).
func unavailable() -> String:
	if in_party():
		return ""   # already seated: the party view must show whatever the login looks like
	if lobby_url() == "":
		return "No lobby is configured."
	if shell.is_offline and not overridden():
		return "Online play needs an online account. Offline characters stay on this device."
	if shell.api == null or _token().is_empty():
		return "Sign in to an online account to play with others."
	return ""


## Tests and staging point the lobby elsewhere: opts `lobby_url` / `lobby_token`, or the launch arg `--lobby=<ws url>` with the token in the
## environment (`DM_LOBBY_TOKEN`). An override also lets an offline character use it (a local test lobby), so it is never the default path.
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


func is_hosting() -> bool:
	return mode == HOST


func in_party() -> bool:
	return mode == HOST or mode == CLIENT


# ---- the window's feed ----------------------------------------------------------------------------------------------------------------

func view() -> Dictionary:
	return {"unavailable": unavailable(), "link": link, "mode": String(mode), "busy": busy, "sessions": sessions, "listed": listed, "code": code,
		"info": info, "error": last_error, "roster": _roster_view(), "open": bool(info.get("open", true)), "max": DmSession.MAX_PLAYERS,
		"username": lobby.username if lobby != null else "", "area": shell.area_id, "host_name": host_name, "default_name": default_name()}


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
	elif mode == SOLO and busy == "":
		close_link()


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
		then.call()
		return
	if lobby != null and link == "connecting":
		_pending = then
		return
	close_link()
	_pending = then
	lobby = DmLobbyClient.new()
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
	set_process(true)
	changed.emit()


func _exit_tree() -> void:
	if lobby != null and mode != HANDOFF:   # a handed-off socket belongs to the client game now
		lobby.close()


func close_link() -> void:
	if lobby != null:
		lobby.close()
	lobby = null
	link = "off"
	_pending = Callable()
	set_process(false)


func _process(dt: float) -> void:
	if lobby == null:
		return
	lobby.poll()
	if watching and mode == SOLO and link == "ready" and busy == "":
		_list_t += dt
		if _list_t >= LIST_EVERY:
			_list_t = 0.0
			lobby.request_list()


func _on_authenticated(_id: int, _name: String) -> void:
	link = "ready"
	_list_t = 0.0
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
	_pending = Callable()
	lobby = null
	_fail("connect", _connection_text(reason))


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
	if mode == HOST:
		_stop_hosting("Lost the connection to the lobby. You are playing solo again.", "err")
	elif mode == SOLO:
		busy = ""
		if watching:
			_fail("connect", _connection_text(reason))
	changed.emit()


func _on_listed(list: Array) -> void:
	sessions = list
	listed = true
	if busy == "listing":
		busy = ""
	last_error = {} if last_error.get("code", "") == "connect" else last_error
	changed.emit()


func _on_lobby_error(c: String, msg: String, _req: String) -> void:
	busy = "" if busy != "listing" else busy
	_fail(c, String(ERROR_TEXT.get(c, msg if msg != "" else "The lobby refused that (%s)." % c)))


func _fail(c: String, text: String) -> void:
	last_error = {"code": c, "text": text}
	notice.emit(text, "err")
	changed.emit()


# ---- hosting ------------------------------------------------------------------------------------------------------------------------------

## Turn this solo session into a hosted one. Private sessions get a code to share; public ones show in everyone's list.
func host_session(session_name: String, is_private: bool = true) -> void:
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
	_ensure_link(func() -> void: lobby.create_session(nm, shell.area_id, is_private))


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
	set_process(false)   # the relay peer polls the socket now
	if shell.rewards != null:
		shell.rewards.local_peer_id = 1
	notice.emit("Hosting \"%s\"%s" % [String(i.get("name", "")), ": share code %s" % c if c != "" else ""], "good")
	hosting_changed.emit(true)
	changed.emit()


func _on_updated(i: Dictionary) -> void:
	info = i
	changed.emit()


## Host: let new players in (true) or keep the session as it is (false; it also leaves the public list).
func set_open(open: bool) -> void:
	if mode != HOST or _relay == null:
		return
	_relay.refuse_new_connections = not open


## Host: remove a player.
func kick(peer_id: int) -> void:
	if mode == HOST:
		shell.session.kick(peer_id)


func _on_lobby_session_closed(reason: String) -> void:
	if mode == HOST:
		_stop_hosting(String(CLOSE_TEXT.get(reason, "The session closed.")) + " You are playing solo again.", "err")
	elif mode == SOLO and busy != "":
		busy = ""
		changed.emit()


## Host: back to a solo game (the world, body and rewards stay): the joiners are dropped, the relay session is closed.
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
		set_process(true)
	if not watching:
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


## The six digits (or a host-chosen code) a friend shared.
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
	print("[coop] joiner: seated in \"%s\" as peer %d, swapping in the client game" % [String(i.get("name", "")), _peer])
	changed.emit()
	join_ready.emit(lobby, i)


## Client game: take over the lobby socket the join happened on (the DmRelayPeer already tunnels through it).
func adopt_client(lobby_: DmLobbyClient, relay: DmRelayPeer) -> void:
	lobby = lobby_
	_relay = relay
	link = "ready"
	mode = CLIENT
	info = lobby.session
	set_process(false)


# ---- leaving / the session ends --------------------------------------------------------------------------------------------------

## The window's Leave: a host stops hosting (the game goes on solo), a client goes back to its own world.
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
	_chat_rate.erase(id)
	if shell.rewards != null and shell.rewards.members.has(key):
		shell.rewards.remove_member(key)
	changed.emit()


# ---- the host <-> joiner handshake ------------------------------------------------------------------------------------------------

## Host (called once the rewards exist): a joiner's rewards and loot follow the party's events.
func attach_host() -> void:
	shell.rewards.member_credited.connect(_on_credited)
	shell.rewards.loot_dropped.connect(_on_loot_dropped)


## Client: once the session is live, tell the host who we are.
func send_profile() -> void:
	if _profile_sent or shell.session.is_host() or not shell.session.is_active():
		return
	_profile_sent = true
	var ch := shell.character
	_rpc_profile.rpc_id(1, {"character_id": int(ch.get("id", 0)), "class_index": int(ch.get("class_index", 0)), "level": int(ch.get("level", 1)),
		"experience": int(ch.get("experience", 0))})


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
	var xp := maxi(0, int(p.get("experience", 0)))
	var key := cid if cid > 0 and not shell.rewards.members.has(cid) else -peer   # a clashing id (two test backends) gets a private key: never credited
	var d := DmCharacterBuild.discipline_for(float(ci))
	body.bind_character({"id": cid, "class_index": ci, "level": lvl})
	var m := DmRewardsMember.make(key, peer, body, null, lvl, {"id": d["id"], "family": d["family"]})
	m.remote = true
	m.prog.character["experience"] = xp
	m.trophy_store = func(_boss: String) -> bool: return false   # a joiner's first-kill trophies are its own backend's business (later)
	m.blocked = "pending_join" if key > 0 else "no_character"
	shell.rewards.add_member(m)
	_members[peer] = key
	_rpc_welcome.rpc_id(peer, shell.rewards.session_id, String(shell.session.character_name))
	changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_welcome(session_id: String, host_name_: String) -> void:
	backend_session = session_id
	host_name = host_name_
	if shell.joiner != null:
		shell.joiner.begin_backend(session_id)
	changed.emit()


## Client -> host: "I joined the backend session with my own account" (ok) or why not. The host starts crediting this member on ok.
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
	else:
		m.blocked = "join_refused"
		shell.rewards.member_refused.emit(key, "join_refused: " + why)
	changed.emit()


func _on_credited(cid: int, delta: Dictionary) -> void:
	var m: DmRewardsMember = shell.rewards.members.get(cid)
	if m == null or not m.remote:
		return
	if int(delta.get("levels", 0)) > 0 and m.body != null and is_instance_valid(m.body):   # its body fights at the new level
		var b := m.body as DmHeroBody
		b.character["level"] = int(m.prog.character["level"])
		b.refresh_stats(shell.build_for(m.peer_id))
		b.restore_vitals()
		var c := b.get_node_or_null("Rites") as DmRiteCaster
		if c != null:
			c.refresh_stats(shell.build_for(m.peer_id))
	_rpc_credit.rpc_id(m.peer_id, delta)


@rpc("authority", "call_remote", "reliable")
func _rpc_credit(delta: Dictionary) -> void:
	if shell.joiner != null:
		shell.joiner.on_credit(delta)


func _on_loot_dropped(cid: int, drop: Dictionary, pos: Vector3) -> void:
	var m: DmRewardsMember = shell.rewards.members.get(cid)
	if m != null and m.remote:
		_rpc_loot.rpc_id(m.peer_id, drop, pos)


@rpc("authority", "call_remote", "reliable")
func _rpc_loot(drop: Dictionary, pos: Vector3) -> void:
	if shell.joiner != null:
		shell.joiner.on_loot(drop, pos)


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
	var now := int(Time.get_ticks_msec() / 1000)
	var r: Array = _chat_rate.get(peer, [now, 0])
	if int(r[0]) != now:
		r = [now, 0]
	r[1] = int(r[1]) + 1
	_chat_rate[peer] = r
	if int(r[1]) > CHAT_PER_S:
		return
	var t := text.strip_edges().substr(0, CHAT_MAX)
	if t != "":
		_broadcast_chat(peer, t)


func _broadcast_chat(peer: int, text: String) -> void:
	var who := ""
	for r in shell.session.get_roster():
		if int(r["peer_id"]) == peer:
			who = String(r["name"])
	_rpc_chat.rpc(who, text)
	_show_chat(who, text)


@rpc("authority", "call_remote", "reliable")
func _rpc_chat(who: String, text: String) -> void:
	_show_chat(who, text)


func _show_chat(who: String, text: String) -> void:
	var line := "[%s] %s" % [who, text]
	chat_log.append(line)
	if chat_log.size() > 40:
		chat_log.pop_front()
	if shell.ui_host != null:
		shell.ui_host.game_event.emit("chat", {"text": line})
