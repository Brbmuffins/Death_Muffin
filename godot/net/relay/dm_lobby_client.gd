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
## Host only: a client entered / left the session (DmRelayPeer turns these into peer_connected / peer_disconnected).
signal peer_joined(peer_id: int, peer_name: String)
signal peer_left(peer_id: int, reason: String)
## The session is over for us: host_left, idle, kicked, shutdown. (We are back in the lobby, socket still open.)
signal session_closed(reason: String)
signal left_session()
signal lobby_error(code: String, message: String, request: String)
signal disconnected(reason: String)

enum State { IDLE, CONNECTING, AUTHENTICATING, LOBBY, IN_SESSION_HOST, IN_SESSION_CLIENT, CLOSED }

const HEADER_BYTES := 11
const KIND_DATA := 1
const BUFFER_BYTES := 1 << 20

var state: int = State.IDLE
var account_id: int = 0
var username: String = ""
var peer_id: int = 0          # 1 = host, 2+ = clients; 0 when not in a session
var session: Dictionary = {}  # last known session info
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

func create_session(session_name: String, area: String, is_private: bool = false, code: String = "") -> void:
	var m := {"t": "create", "name": session_name, "area": area, "private": is_private}
	if code != "":
		m["code"] = code
	_send(m)

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
			state = State.IN_SESSION_HOST
			session_created.emit(session, str(m.get("code", "")))
		"joined":
			session = m.get("session", {})
			peer_id = int(m.get("peerId", 0))
			state = State.IN_SESSION_CLIENT
			session_joined.emit(session, peer_id)
		"session_updated":
			session = m.get("session", {})
			session_updated.emit(session)
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
