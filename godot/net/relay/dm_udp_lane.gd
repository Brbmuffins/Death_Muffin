class_name DmUdpLane
extends RefCounted
## One member's UDP lane to the relay (DmUdpRelay, DECISIONS B31), used by DmRelayPeer next to the lobby WebSocket. Connects with the ticket
## the lobby gave (`created` / `joined` -> DmLobbyClient.relay) and reports what the relay says through callbacks; DmRelayPeer decides
## which packets use it. Anything that goes wrong (no answer in CONNECT_TIMEOUT_MS, a refused ticket, no host on the relay, a dropped
## connection) just ends the lane: the member keeps using the WebSocket.

enum State { CONNECTING, READY, CLOSED }

const CONNECT_TIMEOUT_MS := 3000

var state: int = State.CLOSED
var close_reason := ""
var on_ready: Callable                 ## ()
var on_closed: Callable                ## (reason: String)
var on_packet: Callable                ## (peer: int, mode: int, channel: int, payload: PackedByteArray); peer = source (host) / 1 (client)
var on_attached: Callable              ## host: (peer: int) a client's lane is up
var on_detached: Callable              ## host: (peer: int) a client's lane went down
var sent := 0
var received := 0
var _conn: ENetConnection
var _server: ENetPacketPeer
var _ticket := ""
var _started := 0


func start(addr: String, port: int, ticket: String) -> Error:
	_conn = ENetConnection.new()
	var err := _conn.create_host(1, DmUdpRelay.CHANNELS)
	if err != OK:
		_conn = null
		return err
	_server = _conn.connect_to_host(addr, port, DmUdpRelay.CHANNELS)
	if _server == null:
		_conn.destroy()
		_conn = null
		return ERR_CANT_CONNECT
	_ticket = ticket
	_started = Time.get_ticks_msec()
	state = State.CONNECTING
	return OK


func poll() -> void:
	if _conn == null:
		return
	while _conn != null:
		var ev: Array = _conn.service(0)
		var kind: int = ev[0]
		if kind == ENetConnection.EVENT_NONE:
			break
		match kind:
			ENetConnection.EVENT_CONNECT:
				_server.send(0, JSON.stringify({"t": "attach", "ticket": _ticket}).to_utf8_buffer(), ENetPacketPeer.FLAG_RELIABLE)
			ENetConnection.EVENT_DISCONNECT:
				_finish("relay connection lost" if state == State.READY else (close_reason if close_reason != "" else "relay unreachable"))
			ENetConnection.EVENT_RECEIVE:
				_receive((ev[1] as ENetPacketPeer).get_packet(), int(ev[3]))
	if state == State.CONNECTING and Time.get_ticks_msec() - _started > CONNECT_TIMEOUT_MS:
		_finish("relay did not answer")
	if _conn != null:
		_conn.flush()


func _receive(data: PackedByteArray, channel: int) -> void:
	if channel == 0:
		var m: Variant = JSON.parse_string(data.get_string_from_utf8())
		if not (m is Dictionary):
			return
		match String(m.get("t", "")):
			"ok":
				state = State.READY
				if on_ready.is_valid():
					on_ready.call()
			"error":
				close_reason = String(m.get("code", "error"))
				_finish(close_reason)
			"attached":
				if on_attached.is_valid():
					on_attached.call(int(m.get("id", 0)))
			"detached":
				if on_detached.is_valid():
					on_detached.call(int(m.get("id", 0)))
		return
	if state != State.READY or data.size() < DmUdpRelay.HEADER:
		return
	received += 1
	if on_packet.is_valid():
		on_packet.call(int(data.decode_u32(2)), int(data[0]), int(data[1]), data.slice(DmUdpRelay.HEADER))


## Send a game packet: `peer` = destination for the host, ignored for a client (the relay sends it to the host).
func send(peer: int, mode: int, channel: int, payload: PackedByteArray) -> Error:
	if state != State.READY:
		return ERR_UNCONFIGURED
	var b := PackedByteArray()
	b.resize(DmUdpRelay.HEADER)
	b[0] = mode
	b[1] = clampi(channel, 0, 255)
	b.encode_u32(2, peer)
	b.append_array(payload)
	sent += 1
	return _server.send(DmUdpRelay.channel_for(mode), b, DmUdpRelay.flags_for(mode))


func close() -> void:
	if _conn == null:
		return
	if _server != null and state != State.CLOSED:
		_server.peer_disconnect_now()
	_finish("closed")


func _finish(reason: String) -> void:
	if _conn == null:
		return
	var was := state
	state = State.CLOSED
	close_reason = reason
	_conn.destroy()
	_conn = null
	_server = null
	if was != State.CLOSED and on_closed.is_valid():
		on_closed.call(reason)
