class_name DmUdpRelay
extends Node
## The UDP relay (DECISIONS B31): co-op packets over ENet instead of the lobby's WebSocket, so a lost movement packet no longer stalls
## everything behind it. Same star as the lobby relay: a client reaches only its host, the host reaches each client. Runs as its own
## service (server/death-muffin/relay, `deathmuffin-relay`, UDP 5193) and in-process in tests. Membership stays with the lobby: a member
## proves it may use a session with the ticket the lobby gave it (lobby relayTicket), and the host still drops packets of peers the lobby
## says are gone.
##
## ENet channels: 0 control (reliable JSON), 1 reliable data, 2 unreliable data. A data packet is a 6-byte header + the game packet:
##   [mode u8][channel u8][peer u32 LE]   peer = destination (host -> relay) / source (relay -> host); a client's own value is ignored
## Control: peer -> relay {t: attach, ticket}; relay -> peer {t: ok} | {t: error, code}; relay -> host {t: attached|detached, id}.

const CHANNELS := 3
const HEADER := 6
const MAX_PACKET := 65536 + HEADER
const ATTACH_TIMEOUT_MS := 5000
const RATE_BYTES := 1024 * 1024   ## per peer and second, refilled continuously (burst = 2 s), like the lobby
const RATE_PACKETS := 600
const HOST_ID := 1

var secret := ""
var conn: ENetConnection
var _sessions := {}        ## sid -> {host: ENetPacketPeer, clients: {pid: ENetPacketPeer}}
var _who := {}             ## ENetPacketPeer -> {sid, pid, at, bytes, packets, t}
var _quiet := false
var stats := {"attached": 0, "refused": 0, "forwarded": 0, "dropped": 0}   ## for the service log and tests


## Listen on `bind:port`. Returns the Error from ENet.
func listen(port: int, bind := "*", secret_: String = "", quiet := false) -> Error:
	secret = secret_
	_quiet = quiet
	conn = ENetConnection.new()
	return conn.create_host_bound(bind, port, 512, CHANNELS)


func _process(_dt: float) -> void:
	poll()


func poll() -> void:
	if conn == null:
		return
	var now := Time.get_ticks_msec()
	while true:
		var ev: Array = conn.service(0)
		var kind: int = ev[0]
		if kind == ENetConnection.EVENT_NONE:
			break
		var p: ENetPacketPeer = ev[1]
		match kind:
			ENetConnection.EVENT_CONNECT:
				_who[p] = {"sid": "", "pid": 0, "at": now, "bytes": float(RATE_BYTES * 2), "packets": float(RATE_PACKETS * 2), "t": now}
			ENetConnection.EVENT_DISCONNECT:
				_drop(p)
			ENetConnection.EVENT_RECEIVE:
				_receive(p, p.get_packet(), int(ev[3]), now)
	for p in _who.keys():   # a peer that never attached
		if String(_who[p]["sid"]) == "" and now - int(_who[p]["at"]) > ATTACH_TIMEOUT_MS:
			p.peer_disconnect()
			_who.erase(p)
	conn.flush()


func close() -> void:
	if conn != null:
		conn.destroy()
		conn = null
	_sessions.clear()
	_who.clear()


func _receive(p: ENetPacketPeer, data: PackedByteArray, channel: int, now: int) -> void:
	var w: Variant = _who.get(p)
	if w == null:
		return
	if not _spend(w, data.size(), now):
		stats["dropped"] += 1
		return
	if channel == 0:
		var m: Variant = JSON.parse_string(data.get_string_from_utf8())
		if m is Dictionary and String(m.get("t", "")) == "attach" and String(w["sid"]) == "":
			_attach(p, String(m.get("ticket", "")))
		return
	if String(w["sid"]) == "" or data.size() < HEADER or data.size() > MAX_PACKET:
		stats["dropped"] += 1
		return
	var s: Dictionary = _sessions.get(String(w["sid"]), {})
	var mode := data[0]
	if int(w["pid"]) == HOST_ID:
		var dst := data.decode_u32(2)
		var to: ENetPacketPeer = (s.get("clients", {}) as Dictionary).get(dst)
		if to == null:
			stats["dropped"] += 1
			return
		data.encode_u32(2, HOST_ID)
		_send(to, mode, data)
	else:
		var host: ENetPacketPeer = s.get("host")
		if host == null:
			stats["dropped"] += 1
			return
		data.encode_u32(2, int(w["pid"]))
		_send(host, mode, data)


func _send(to: ENetPacketPeer, mode: int, data: PackedByteArray) -> void:
	stats["forwarded"] += 1
	to.send(channel_for(mode), data, flags_for(mode))


## MultiplayerPeer transfer mode -> ENet channel / flags (shared with DmUdpLane).
static func channel_for(mode: int) -> int:
	return 1 if mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE else 2


static func flags_for(mode: int) -> int:
	match mode:
		MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			return ENetPacketPeer.FLAG_RELIABLE
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
			return ENetPacketPeer.FLAG_UNSEQUENCED
	return 0   # UNRELIABLE_ORDERED: ENet's sequenced unreliable


func _attach(p: ENetPacketPeer, ticket: String) -> void:
	var t := verify(secret, ticket, int(Time.get_unix_time_from_system() * 1000.0))
	if not t.has("sid"):
		_refuse(p, String(t.get("error", "bad_ticket")))
		return
	var sid := String(t["sid"]); var pid := int(t["pid"])
	var s: Dictionary = _sessions.get(sid, {"host": null, "clients": {}})
	if pid == HOST_ID:
		var old: ENetPacketPeer = s.get("host")
		if old != null and old != p:
			_who.erase(old)
			old.peer_disconnect()
		s["host"] = p
	else:
		if s.get("host") == null:
			_refuse(p, "no_host")   # the host is not on the relay: this member stays on the WebSocket
			return
		var oldc: ENetPacketPeer = (s["clients"] as Dictionary).get(pid)
		if oldc != null and oldc != p:
			_who.erase(oldc)
			oldc.peer_disconnect()
		s["clients"][pid] = p
	_sessions[sid] = s
	_who[p]["sid"] = sid
	_who[p]["pid"] = pid
	stats["attached"] += 1
	_ctl(p, {"t": "ok"})
	if pid != HOST_ID:
		_ctl(s["host"], {"t": "attached", "id": pid})
	_log("attached %s/%d" % [sid, pid])


func _drop(p: ENetPacketPeer) -> void:
	var w: Variant = _who.get(p)
	_who.erase(p)
	if w == null or String(w["sid"]) == "":
		return
	var sid := String(w["sid"]); var pid := int(w["pid"])
	var s: Dictionary = _sessions.get(sid, {})
	if s.is_empty():
		return
	if pid == HOST_ID:
		if s.get("host") != p:
			return
		for c in (s["clients"] as Dictionary).values():   # the host left the relay: its clients go back to the WebSocket
			_ctl(c, {"t": "error", "code": "host_gone"})
			_who.erase(c)
			c.peer_disconnect_later()
		_sessions.erase(sid)
	elif (s["clients"] as Dictionary).get(pid) == p:
		(s["clients"] as Dictionary).erase(pid)
		if s.get("host") != null:
			_ctl(s["host"], {"t": "detached", "id": pid})
	_log("detached %s/%d" % [sid, pid])


func _refuse(p: ENetPacketPeer, code: String) -> void:
	stats["refused"] += 1
	_ctl(p, {"t": "error", "code": code})
	_who.erase(p)
	p.peer_disconnect_later()


static func _ctl(p: ENetPacketPeer, m: Dictionary) -> void:
	p.send(0, JSON.stringify(m).to_utf8_buffer(), ENetPacketPeer.FLAG_RELIABLE)


func _spend(w: Dictionary, n: int, now: int) -> bool:
	var dt := float(now - int(w["t"])) / 1000.0
	w["t"] = now
	w["bytes"] = minf(float(RATE_BYTES * 2), float(w["bytes"]) + dt * RATE_BYTES) - n
	w["packets"] = minf(float(RATE_PACKETS * 2), float(w["packets"]) + dt * RATE_PACKETS) - 1.0
	return float(w["bytes"]) >= 0.0 and float(w["packets"]) >= 0.0


## A lobby ticket "<sid>.<pid>.<expires ms>.<hmac hex>" -> {sid, pid} or {error}. Same HMAC as the lobby's relayTicket.
static func verify(secret_: String, ticket: String, now_ms: int) -> Dictionary:
	var parts := ticket.split(".")
	if secret_ == "" or parts.size() != 4 or not parts[1].is_valid_int() or not parts[2].is_valid_int():
		return {"error": "bad_ticket"}
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, secret_.to_utf8_buffer())
	ctx.update(("dm-relay|%s|%s|%s" % [parts[0], parts[1], parts[2]]).to_utf8_buffer())
	var want := ctx.finish().hex_encode()
	var got := parts[3]
	var diff := want.length() ^ got.length()
	for i in mini(want.length(), got.length()):
		diff |= want.unicode_at(i) ^ got.unicode_at(i)
	if diff != 0:
		return {"error": "bad_ticket"}
	if int(parts[2]) < now_ms:
		return {"error": "expired"}
	return {"sid": parts[0], "pid": int(parts[1])}


func _log(line: String) -> void:
	if not _quiet:
		print("[relay] " + line)
