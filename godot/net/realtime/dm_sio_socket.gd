class_name DmSioSocket
extends RefCounted
## Minimal Socket.IO v4 client (Engine.IO v4, WebSocket transport only) over WebSocketPeer. One instance = one connection attempt
## (like the TS `io(url, {reconnection: false})`); reconnection is the caller's policy (DmRtReconnector).
## Supports: EIO open/ping/pong/close, namespace CONNECT with an auth payload, EVENT with JSON args, ACK (both ways), DISCONNECT,
## CONNECT_ERROR. Binary attachments (types 5/6) are not used by the server and are ignored.
## It polls itself from SceneTree.process_frame; `poll()` is public so tests can drive it by hand.

signal connected(sid: String)
signal connect_error(message: String)
signal disconnected(reason: String)
signal event_received(event: String, args: Array)

enum State { IDLE, CONNECTING, OPEN, CONNECTED, CLOSED }

var state: int = State.IDLE
var sid: String = ""
var namespace_name: String = "/"

var _ws: WebSocketPeer
var _auth: Variant = null
var _timeout_ms: int = 6000
var _t_open: int = 0
var _eio_open: bool = false
var _ping_interval_ms: int = 25000
var _ping_timeout_ms: int = 20000
var _last_ping_ms: int = 0
var _next_ack_id: int = 0
var _acks: Dictionary = {}
var _tree: SceneTree
var _driven: bool = false

## base_url: "https://host" / "http://127.0.0.1:5300" (or ws/wss). path: Socket.IO path ("" = default "/socket.io").
func open(base_url: String, path: String, auth: Variant, timeout_s: float = 6.0, ns: String = "/") -> void:
	if state != State.IDLE:
		return
	namespace_name = ns if ns.begins_with("/") else "/" + ns
	_auth = auth
	_timeout_ms = int(timeout_s * 1000.0)
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 20  # snapshots reach 96 KiB
	_ws.outbound_buffer_size = 1 << 18
	_ws.max_queued_packets = 4096
	var url := build_url(base_url, path)
	state = State.CONNECTING
	_t_open = Time.get_ticks_msec()
	var err := _ws.connect_to_url(url)
	if err != OK:
		_fail("websocket error")
		return
	_tree = Engine.get_main_loop() as SceneTree
	if _tree != null:
		_tree.process_frame.connect(poll)
		_driven = true

static func build_url(base_url: String, path: String) -> String:
	var b := base_url.strip_edges()
	while b.ends_with("/"):
		b = b.substr(0, b.length() - 1)
	if b.begins_with("https://"):
		b = "wss://" + b.substr(8)
	elif b.begins_with("http://"):
		b = "ws://" + b.substr(7)
	var p := path if not path.is_empty() else "/socket.io"
	if not p.begins_with("/"):
		p = "/" + p
	while p.ends_with("/") and p.length() > 1:
		p = p.substr(0, p.length() - 1)
	return "%s%s/?EIO=4&transport=websocket" % [b, p]

func is_connected_to_server() -> bool:
	return state == State.CONNECTED

## Fire-and-forget or acked emit. `args` are the event arguments after the name. volatile: dropped silently unless connected (the
## non-volatile path drops too: there is no offline buffer, the game re-joins on reconnect).
func emit_event(event: String, args: Array = [], ack: Callable = Callable()) -> void:
	if state != State.CONNECTED:
		return
	var payload: Array = [event]
	payload.append_array(args)
	var head := "42" + _ns_prefix()
	if ack.is_valid():
		var id := _next_ack_id
		_next_ack_id += 1
		_acks[id] = ack
		head += str(id)
	_ws.send_text(head + JSON.stringify(payload))

## Orderly close from our side (socket.disconnect()). Emits no signals: the caller asked for it.
func close() -> void:
	if state == State.CLOSED:
		return
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if state == State.CONNECTED:
			_ws.send_text("41" + _ns_prefix().trim_suffix(","))
		_ws.close(1000, "client disconnect")
	_finish()

func _ns_prefix() -> String:
	return "" if namespace_name == "/" else namespace_name + ","

func _finish() -> void:
	state = State.CLOSED
	_acks.clear()
	if _driven and _tree != null and _tree.process_frame.is_connected(poll):
		_tree.process_frame.disconnect(poll)
	_driven = false

func _fail(message: String) -> void:
	var was_connected := state == State.CONNECTED
	if _ws != null and _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close()
	_finish()
	if was_connected:
		disconnected.emit(message)
	else:
		connect_error.emit(message)

func poll() -> void:
	if state == State.IDLE or state == State.CLOSED:
		return
	_ws.poll()
	var now := Time.get_ticks_msec()
	var rs := _ws.get_ready_state()
	if rs == WebSocketPeer.STATE_CONNECTING:
		if now - _t_open > _timeout_ms:
			_fail("timeout")
		return
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		if _ws.was_string_packet():
			_on_text(pkt.get_string_from_utf8())
		if state == State.CLOSED:
			return
	rs = _ws.get_ready_state()
	if rs == WebSocketPeer.STATE_CLOSED:
		_fail("transport close" if state == State.CONNECTED else "websocket error")
		return
	if state == State.OPEN and now - _t_open > _timeout_ms:
		_fail("timeout")  # EIO open but the namespace never answered
		return
	if _eio_open and now - _last_ping_ms > _ping_interval_ms + _ping_timeout_ms:
		_fail("ping timeout")

func _on_text(text: String) -> void:
	if text.is_empty():
		return
	match text[0]:
		"0":  # EIO open
			var open: Variant = JSON.parse_string(text.substr(1))
			if open is Dictionary:
				_ping_interval_ms = int(open.get("pingInterval", 25000))
				_ping_timeout_ms = int(open.get("pingTimeout", 20000))
			_eio_open = true
			_last_ping_ms = Time.get_ticks_msec()
			state = State.OPEN
			var connect_pkt := "40" + _ns_prefix()
			if _auth != null:
				connect_pkt += JSON.stringify(_auth)
			elif namespace_name != "/":
				connect_pkt = connect_pkt.trim_suffix(",")
			_ws.send_text(connect_pkt)
		"2":  # ping -> pong
			_last_ping_ms = Time.get_ticks_msec()
			_ws.send_text("3")
		"1":
			_fail("transport close")
		"4":
			_on_sio_packet(text.substr(1))

func _on_sio_packet(body: String) -> void:
	if body.is_empty():
		return
	var type := int(body[0])
	var i := 1
	if type == 5 or type == 6:
		return  # binary: unused by this server
	var ns := "/"
	if i < body.length() and body[i] == "/":
		var comma := body.find(",", i)
		if comma == -1:
			ns = body.substr(i)
			i = body.length()
		else:
			ns = body.substr(i, comma - i)
			i = comma + 1
	if ns != namespace_name:
		return
	var id := -1
	var j := i
	while j < body.length() and body[j] >= "0" and body[j] <= "9":
		j += 1
	if j > i:
		id = int(body.substr(i, j - i))
		i = j
	var data: Variant = DmJson.parse(body.substr(i)) if i < body.length() else null
	match type:
		0:  # CONNECT
			if data is Dictionary:
				sid = str(data.get("sid", ""))
			state = State.CONNECTED
			connected.emit(sid)
		1:  # DISCONNECT
			_fail("io server disconnect")
		2:  # EVENT
			if data is Array and (data as Array).size() > 0:
				var a: Array = data
				var ev := str(a[0])
				var args: Array = a.slice(1)
				if id >= 0 and state == State.CONNECTED:
					# server asked for an ack: none of our listeners use it; answer empty so the peer does not wait.
					_ws.send_text("43" + _ns_prefix() + str(id) + "[]")
				event_received.emit(ev, args)
		3:  # ACK
			if _acks.has(id):
				var cb: Callable = _acks[id]
				_acks.erase(id)
				cb.call(data if data is Array else [])
		4:  # CONNECT_ERROR
			var msg := "connect_error"
			if data is Dictionary:
				msg = str(data.get("message", msg))
			elif data is String:
				msg = data
			_fail(msg)
