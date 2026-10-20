class_name DmLobbyClient
extends RefCounted
## Client for the Death Muffin lobby + relay service (server/death-muffin/lobby). One WebSocket per client: first the lobby
## (list / create / join / leave), then, once in a session, the same socket carries the game packets for DmRelayPeer.
## Nothing here is a Node: call poll() every frame yourself (DmRelayPeer does it for you once it is attached).
##
##   var lobby := DmLobbyClient.new()
##   lobby.connect_to_lobby("wss://muffindevelopment.com/death-muffin/lobby/", jwt)
##   await lobby.authenticated          # or connection_failed(reason)
##   lobby.create_session("My run", "hollow-graves")   # -> session_created(info, code)
##   var peer := DmRelayPeer.new(); peer.host(lobby)   # then multiplayer.multiplayer_peer = peer

signal authenticated(account_id: int, username: String)
signal connection_failed(reason: String)
signal sessions_listed(sessions: Array)
signal session_created(info: Dictionary, code: String)
signal session_joined(info: Dictionary, peer_id: int)
signal session_updated(info: Dictionary)
signal world_changed(heat: int, difficulty: String)   ## a member: the host's world changed (DECISIONS B26); `session` already holds it
## Host only: a client entered / left the session (DmRelayPeer turns these into peer_connected / peer_disconnected).
signal peer_joined(peer_id: int, peer_name: String)
signal peer_left(peer_id: int, reason: String)
## The session is over for us: host_left, idle, kicked, shutdown. (We are back in the lobby, socket still open.)
signal session_closed(reason: String)
signal left_session()
signal lobby_error(code: String, message: String, request: String)
signal disconnected(reason: String)
## Friends (lobby README "Friends"): online mutual friends on connect / after a list change, then one line per change (p = {} : went offline).
## p: {accountId, username, class, level, area, session: {id, private, open, players, max, host, isHost} or null}
signal friends_snapshot(list: Array)
signal friend_presence(account_id: int, p: Dictionary)
signal friends_changed()                                   ## someone answered or removed us: reload the friends list
signal invited(from_name: String, from_id: int, info: Dictionary, auto: bool)   ## auto: the answer to our own ask to join
signal invite_sent(account_id: int, user: String)
signal join_requested(account_id: int, user: String, via: String)   ## a friend (via: a friend of theirs in our party) asks to join us
signal ask_sent(account_id: int, user: String)
signal ask_declined(user: String)
## Our connection to a session dropped (not a leave or a removal): it keeps our place for a few minutes. `ms` is the window left; `from_name` / `from_id` the host; joining `info.id` needs no code (lobby README "Rejoin window").
signal rejoin_offered(from_name: String, from_id: int, info: Dictionary, ms: int)

enum State { IDLE, CONNECTING, AUTHENTICATING, LOBBY, IN_SESSION_HOST, IN_SESSION_CLIENT, CLOSED }

const HEADER_BYTES := 11
const KIND_DATA := 1
const BUFFER_BYTES := 1 << 20

var state: int = State.IDLE
var account_id: int = 0
var username: String = ""
var peer_id: int = 0          # 1 = host, 2+ = clients; 0 when not in a session
var session: Dictionary = {}  # last known session info
## The UDP relay lane for this member ({addr, port, ticket}) from `created` / `joined`; {} when the lobby has no relay (DmRelayPeer then stays on this socket).
var relay: Dictionary = {}
var max_players: int = 4
var last_error: Dictionary = {}
## Traffic counters (game packets only, header included): a hosted session's network cost, read by the tests and the perf overlay.
var packets_out := 0
var bytes_out := 0
var packets_in := 0
var bytes_in := 0

## Binary frames from the relay go here: func(src: int, mode: int, channel: int, payload: PackedByteArray). Set by DmRelayPeer. Frames that arrive
## while no sink is set (a joiner's game is still being swapped in after `session_joined`) are kept and handed over, in order, when it is set.
var packet_sink: Callable = Callable():
	set(v):
		packet_sink = v
		if v.is_valid():
			var backlog := _backlog
			_backlog = []
			_backlog_bytes = 0
			for f in backlog:
				v.call(f[0], f[1], f[2], f[3])
const BACKLOG_MAX_BYTES := 4 << 20
var _backlog: Array = []
var _backlog_bytes := 0

var _ws: WebSocketPeer
var _token := ""
var _closed_reported := false

func connect_to_lobby(url: String, token: String) -> Error:
	close()
	_token = token
	_closed_reported = false
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = BUFFER_BYTES
	_ws.outbound_buffer_size = BUFFER_BYTES
	_ws.max_queued_packets = 4096
	var err := _ws.connect_to_url(url)
	if err != OK:
		_ws = null
		state = State.CLOSED
		return err
	state = State.CONNECTING
	return OK

func is_open() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

func in_session() -> bool:
	return state == State.IN_SESSION_HOST or state == State.IN_SESSION_CLIENT

func request_list() -> void:
	_send({"t": "list"})

## `world` = {heat, difficulty}: the host's world, shown with the session everywhere (DECISIONS B26); later changes go through set_world.
func create_session(session_name: String, area: String, is_private: bool = false, code: String = "", world: Dictionary = {}) -> void:
	var m := {"t": "create", "name": session_name, "area": area, "private": is_private}
	if code != "":
		m["code"] = code
	if world.has("heat"):
		m["heat"] = int(world["heat"])
	if world.has("difficulty"):
		m["difficulty"] = String(world["difficulty"])
	_send(m)

## Host only: its world's heat (world vows) and difficulty changed; members, friends and the session list follow.
func set_world(heat: int, difficulty: String) -> void:
	_send({"t": "world", "heat": heat, "difficulty": difficulty})

func join_session(session_id: String, code: String = "") -> void:
	var m := {"t": "join", "id": session_id}
	if code != "":
		m["code"] = code
	_send(m)

## Join a private session by its code alone (private sessions are not in the list).
func join_by_code(code: String) -> void:
	_send({"t": "join", "code": code})

## Leave the session (a host leaving ends it for everyone). The socket stays open in the lobby.
func leave() -> void:
	if in_session():
		_send({"t": "leave"})

## Host only: stop or allow new players (hides the session from the list while closed).
func set_open(open: bool) -> void:
	_send({"t": "set_open", "open": open})

## Host only.
func kick(target_peer_id: int) -> void:
	_send({"t": "kick", "id": target_peer_id})

## Host only: Closed (invite only, not listed) or Open (listed, anyone joins).
func set_private(closed: bool) -> void:
	_send({"t": "set_private", "private": closed})

## What friends see of us: discipline index, level, area id.
func send_presence(class_index: int, level: int, area: String) -> void:
	_send({"t": "presence", "class": class_index, "level": level, "area": area})

## We changed a friendship with `other` (0 = unknown): the lobby reloads both lists.
func send_friends_changed(other: int) -> void:
	_send({"t": "friends_changed", "accountId": other})

## Host only: let a friend in (also through a Closed door) for a few minutes.
func invite(friend_id: int) -> void:
	_send({"t": "invite", "accountId": friend_id})

func ask(friend_id: int) -> void:
	_send({"t": "ask", "accountId": friend_id})

func answer(asker_id: int, accept: bool) -> void:
	_send({"t": "answer", "accountId": asker_id, "accept": accept})

## Send an opaque game packet to dst (0 = every client, host only).
func send_packet(dst: int, mode: int, channel: int, payload: PackedByteArray) -> Error:
	if not is_open() or not in_session():
		return ERR_UNCONFIGURED
	var b := PackedByteArray()
	b.resize(HEADER_BYTES)
	b[0] = KIND_DATA
	b[1] = mode & 0xFF
	b[2] = channel & 0xFF
	b.encode_u32(3, peer_id)   # the relay overwrites this with the true source
	b.encode_u32(7, dst)
	b.append_array(payload)
	packets_out += 1
	bytes_out += b.size()
	return _ws.send(b, WebSocketPeer.WRITE_MODE_BINARY)

func close() -> void:
	if _ws != null:
		_ws.close(1000, "bye")
	_ws = null
	if state != State.IDLE:
		state = State.CLOSED
	peer_id = 0

func poll() -> void:
	if _ws == null:
		return
	_ws.poll()
	var rs := _ws.get_ready_state()
	if rs == WebSocketPeer.STATE_CLOSED:
		var code := _ws.get_close_code()
		var why := _ws.get_close_reason()
		var was_state := state
		_ws = null
		peer_id = 0
		state = State.CLOSED
		if not _closed_reported:
			_closed_reported = true
			var reason := why if why != "" else "closed (%d)" % code
			if was_state == State.CONNECTING or was_state == State.AUTHENTICATING:
				connection_failed.emit(reason)
			else:
				disconnected.emit(reason)
		return
	if rs == WebSocketPeer.STATE_OPEN and state == State.CONNECTING:
		state = State.AUTHENTICATING
		_send({"t": "auth", "token": _token})
	if rs != WebSocketPeer.STATE_OPEN and rs != WebSocketPeer.STATE_CLOSING:
		return
	while _ws != null and _ws.get_available_packet_count() > 0:
		var data := _ws.get_packet()
		var is_text := _ws.was_string_packet() # describes the packet just read, so ask AFTER get_packet()
		if is_text:
			_on_text(data.get_string_from_utf8())
		else:
			_on_binary(data)

func _send(m: Dictionary) -> void:
	if is_open():
		_ws.send_text(JSON.stringify(m))

func _on_binary(data: PackedByteArray) -> void:
	if data.size() < HEADER_BYTES or data[0] != KIND_DATA or not in_session():
		return
	packets_in += 1
	bytes_in += data.size()
	if packet_sink.is_valid():
		packet_sink.call(data.decode_u32(3), data[1], data[2], data.slice(HEADER_BYTES))
	elif _backlog_bytes + data.size() <= BACKLOG_MAX_BYTES:
		_backlog_bytes += data.size()
		_backlog.append([data.decode_u32(3), data[1], data[2], data.slice(HEADER_BYTES)])

func _on_text(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var m: Dictionary = parsed
	match str(m.get("t", "")):
		"ready":
			state = State.LOBBY
			account_id = int(m.get("accountId", 0))
			username = str(m.get("username", ""))
			max_players = int(m.get("maxPlayers", 4))
			authenticated.emit(account_id, username)
		"sessions":
			sessions_listed.emit(m.get("sessions", []))
		"created":
			session = m.get("session", {})
			peer_id = int(m.get("peerId", 1))
			relay = m.get("relay") if m.get("relay") is Dictionary else {}
			state = State.IN_SESSION_HOST
			session_created.emit(session, str(m.get("code", "")))
		"joined":
			session = m.get("session", {})
			peer_id = int(m.get("peerId", 0))
			relay = m.get("relay") if m.get("relay") is Dictionary else {}
			state = State.IN_SESSION_CLIENT
			session_joined.emit(session, peer_id)
		"session_updated":
			session = m.get("session", {})
			session_updated.emit(session)
		"world":
			session["heat"] = int(m.get("heat", 0))
			session["difficulty"] = str(m.get("difficulty", "medium"))
			world_changed.emit(int(session["heat"]), String(session["difficulty"]))
		"peer_joined":
			peer_joined.emit(int(m.get("id", 0)), str(m.get("name", "")))
		"peer_left":
			peer_left.emit(int(m.get("id", 0)), str(m.get("reason", "")))
		"session_closed":
			_backlog = []
			_backlog_bytes = 0
			if in_session():
				state = State.LOBBY
				peer_id = 0
				session = {}
			session_closed.emit(str(m.get("reason", "")))
		"left":
			state = State.LOBBY
			peer_id = 0
			session = {}
			left_session.emit()
		"error":
			last_error = m
			lobby_error.emit(str(m.get("code", "")), str(m.get("msg", "")), str(m.get("req", "")))
		"replaced":
			pass # the close frame (4402) follows and is reported as disconnected("replaced")
		"friends":
			friends_snapshot.emit(m.get("list", []))
		"presence":
			var pr: Variant = m.get("p")
			friend_presence.emit(int(m.get("accountId", 0)), pr if pr is Dictionary else {})
		"friends_changed":
			friends_changed.emit()
		"invited":
			invited.emit(str(m.get("from", "")), int(m.get("fromId", 0)), m.get("session", {}), bool(m.get("auto", false)))
		"invite_sent":
			invite_sent.emit(int(m.get("accountId", 0)), str(m.get("username", "")))
		"join_request":
			join_requested.emit(int(m.get("accountId", 0)), str(m.get("username", "")), str(m.get("via", "")) if m.get("via") != null else "")
		"ask_sent":
			ask_sent.emit(int(m.get("accountId", 0)), str(m.get("username", "")))
		"ask_declined":
			ask_declined.emit(str(m.get("username", "")))
		"rejoin":
			rejoin_offered.emit(str(m.get("from", "")), int(m.get("fromId", 0)), m.get("session", {}), int(m.get("ms", 0)))
