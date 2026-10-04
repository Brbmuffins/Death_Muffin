class_name DmRtClient
extends RefCounted
## Realtime co-op client: port of src/net/realtime.ts on top of DmSioSocket. Same surface as the old DmRealtimeClient stub
## (net/dm_realtime_client.gd) so the game scene can swap it in. Solo play never depends on it: `connect_to_world` returns a failed
## DmResult when the service is down, and every sender is a no-op while disconnected.
##
## Typical use (see tests/realtime/run.gd):
##   var rt := DmRtClient.new()
##   rt.snapshot_received.connect(...)  # all signals fire only after a successful join, like the TS handlers
##   var r: DmResult = await rt.connect_to_world(token, {"characterId": 1, "classIndex": 0, "x": 0, "z": 0, "facing": 0})
##   if r.ok: r.data == JoinResult {self, players, hostId, instance, solo?, snapshot}
##
## Payload numbers come back through DmJson (integral JSON numbers are ints, others floats).

signal player_joined(player: Dictionary)
signal player_left(id: String)
signal player_moved(update: Dictionary)
signal player_gear(update: Dictionary)
signal chat_received(message: Dictionary)
signal intent_received(envelope: Dictionary)
signal snapshot_received(snapshot: Dictionary)
signal events_received(batch: Array)
signal host_changed(host_id: String, snapshot: Variant)
signal disconnected
## A newer login of this account exists. Pushed by the relay (`session:replaced`) AND raised when a (re)join is refused with
## "this account was opened somewhere else". Godot's WebSocketPeer can drop the last data frame when the server closes the socket
## right behind it (seen with this push), so the refused rejoin is the reliable signal; the REST session probe is the third.
signal session_replaced
## Internal: a connect/join attempt finished (DmResult).
signal _attempt_done(result: DmResult)

## How long a join may wait for its answer once the socket is up (JOIN_TIMEOUT_MS).
const JOIN_TIMEOUT_S := 8.0
const CONNECT_TIMEOUT_S := 6.0
const UNREACHABLE := "Co-op service unreachable — playing solo"

var instance: String = ""
var host_id: String = ""
var self_id: String = ""
## Overridable for local tests; default to the production endpoint (DmConfig).
var base_url: String = DmConfig.WS_BASE
var ws_path: String = DmConfig.WS_PATH
## Message counters for QA / the debug overlay (same keys as the TS client).
var stats := {"snapIn": 0, "snapOut": 0, "evIn": 0, "evOut": 0, "intentIn": 0, "intentOut": 0, "moveIn": 0}

var _sock: DmSioSocket
var _joined: bool = false
var _pending: bool = false
var _gen: int = 0
var _last_result: DmResult

func is_connected_to_world() -> bool:
	return _sock != null and _sock.is_connected_to_server()

func is_host() -> bool:
	return is_connected_to_world() and host_id == self_id

## request: JoinRequest {instance?, characterId, classIndex, level?, x, z, facing, gear?}. Awaitable. Returns a DmResult whose data is
## the JoinResult, or an error: UNREACHABLE (retryable), "Realtime service not configured" / "Not authenticated" (final), or the
## server's player-readable rejection ("That world is full (10 players)", ...).
func connect_to_world(token: String, request: Dictionary) -> DmResult:
	if base_url.is_empty():
		return DmResult.failure("Realtime service not configured", 0)
	if token.is_empty():
		return DmResult.failure("Not authenticated", 0)
	_drop_socket()  # a retry replaces the dead socket
	_gen += 1
	var gen := _gen
	_pending = true
	var sock := DmSioSocket.new()
	_sock = sock
	sock.connect_error.connect(func(msg: String) -> void:
		if gen != _gen or not _pending:
			return
		var m := UNREACHABLE if msg in ["xhr poll error", "websocket error", "timeout"] else msg
		_finish_attempt(DmResult.failure(m, 0), sock))
	sock.connected.connect(func(sid: String) -> void:
		if gen != _gen:
			return
		self_id = sid
		_start_join(sock, gen, request))
	sock.disconnected.connect(func(_reason: String) -> void:
		if gen != _gen:
			return
		if _pending:
			_finish_attempt(DmResult.failure(UNREACHABLE, 0), sock)  # the link dropped before the join was answered
		elif _joined:
			_joined = false
			disconnected.emit())
	sock.event_received.connect(func(ev: String, args: Array) -> void:
		if gen == _gen and _joined:
			_route(ev, args))
	sock.open(base_url, ws_path, {"token": token}, CONNECT_TIMEOUT_S)
	if not _pending:
		return _last_result  # failed synchronously (bad URL)
	return await _attempt_done

func _start_join(sock: DmSioSocket, gen: int, request: Dictionary) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.create_timer(JOIN_TIMEOUT_S).timeout.connect(func() -> void:
			if gen == _gen and _pending:
				_finish_attempt(DmResult.failure(UNREACHABLE, 0), sock))
	sock.emit_event("world:join", [request], func(args: Array) -> void:
		if gen != _gen or not _pending:
			return
		var res: Variant = args[0] if args.size() > 0 else null
		if not (res is Dictionary) or not bool(res.get("success", false)) or not (res.get("data") is Dictionary):
			var err := "Could not join the world"
			if res is Dictionary and res.has("error"):
				err = str(res["error"])
			_finish_attempt(DmResult.failure(err, 0), sock)
			return
		var data: Dictionary = res["data"]
		host_id = str(data.get("hostId", ""))
		instance = str(data.get("instance", ""))
		_joined = true
		_finish_attempt(DmResult.success(data), sock))

func _finish_attempt(result: DmResult, sock: DmSioSocket) -> void:
	_pending = false
	_last_result = result
	if not result.ok:
		_joined = false
		sock.close()
		if _sock == sock:
			_sock = null
		if result.error.contains("opened somewhere else"):
			session_replaced.emit()  # a newer login exists: same meaning as the relay's session:replaced push
	_attempt_done.emit(result)

func _route(ev: String, args: Array) -> void:
	var a: Variant = args[0] if args.size() > 0 else null
	match ev:
		"player:join":
			if a is Dictionary: player_joined.emit(a)
		"player:leave":
			if a is Dictionary: player_left.emit(str(a.get("id", "")))
		"player:move":
			if a is Dictionary:
				stats["moveIn"] += 1
				player_moved.emit(a)
		"player:gear":
			if a is Dictionary: player_gear.emit(a)
		"chat:message":
			if a is Dictionary: chat_received.emit(a)
		"world:intent":
			if a is Dictionary:
				stats["intentIn"] += 1
				intent_received.emit(a)
		"world:snapshot":
			if a is Dictionary:
				stats["snapIn"] += 1
				snapshot_received.emit(a)
		"world:events":
			if a is Array:
				stats["evIn"] += 1
				events_received.emit(a)
		"room:host":
			if a is Dictionary:
				host_id = str(a.get("hostId", ""))
				host_changed.emit(host_id, a.get("snapshot"))
		"session:replaced":
			session_replaced.emit()

func send_gear(gear: Dictionary) -> void:
	if _joined: _sock.emit_event("player:gear", [gear])

func send_move(update: Dictionary) -> void:
	if _joined: _sock.emit_event("player:move", [update])

func send_intent(intent: Dictionary) -> void:
	stats["intentOut"] += 1
	if _joined: _sock.emit_event("world:intent", [intent])

func send_snapshot(snapshot: Dictionary) -> void:
	stats["snapOut"] += 1
	if _joined: _sock.emit_event("world:snapshot", [snapshot])

func send_events(batch: Array) -> void:
	if batch.is_empty():
		return
	stats["evOut"] += 1
	if _joined: _sock.emit_event("world:events", [batch])

## Performance beacon (perfBeacon.ts): fire-and-forget.
func send_perf(payload: Dictionary) -> void:
	if _joined: _sock.emit_event("perf:report", [payload])

func send_chat(text: String) -> void:
	if _joined: _sock.emit_event("chat:send", [text])

func disconnect_from_world() -> void:
	_drop_socket()
	host_id = ""
	self_id = ""

func _drop_socket() -> void:
	_gen += 1  # silences every callback of the old socket
	_joined = false
	if _pending:
		_pending = false
		_attempt_done.emit(DmResult.failure(UNREACHABLE, 0))
	if _sock != null:
		_sock.close()
		_sock = null

# --- Reconnection policy (port of src/net/reconnect.ts) -------------------------------------------------------------------------

## After a dropped link: 1 s, 2 s, 4 s, 8 s, then every 15 s.
static func rejoin_delay_ms(attempt: int) -> int:
	return mini(15000, 1000 * (1 << maxi(0, attempt)))

## First connect found the service down: 10 s, 20 s, then every 30 s.
static func first_connect_delay_ms(attempt: int) -> int:
	return mini(30000, 10000 * (maxi(0, attempt) + 1))

## mode: "first" | "rejoin"
static func is_retryable_error(message: String, mode: String) -> bool:
	var m := message.to_lower()
	if m.contains("not configured") or m.contains("not authenticated"):
		return false
	for needle in ["unreachable", "timeout", "timed out", "xhr poll error", "websocket error", "transport", "network", "econnrefused", "failed to fetch"]:
		if m.contains(needle):
			return true
	return mode == "rejoin" and (m.contains("already in this world") or m.contains("already in a world"))
