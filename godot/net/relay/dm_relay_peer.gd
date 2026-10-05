class_name DmRelayPeer
extends MultiplayerPeerExtension
## Godot high-level multiplayer tunnelled through the Death Muffin lobby relay (server/death-muffin/lobby).
## Drop-in for ENetMultiplayerPeer: assign it to `multiplayer.multiplayer_peer` after it is attached.
##
##   Host:    lobby.create_session(...); await lobby.session_created; var p := DmRelayPeer.new(); p.host(lobby)
##   Client:  lobby.join_session(id);    await lobby.session_joined;  var p := DmRelayPeer.new(); p.join(lobby)
##   then:    multiplayer.multiplayer_peer = p
##
## Unique ids: host is always 1, clients are 2, 3, 4... assigned by the relay (never reused within a session).
## Topology: star. Clients only reach the host; client-to-client RPCs work through Godot's own server relay
## (SceneMultiplayer.server_relay, default on) because _is_server_relay_supported() is true.
## Transport: one WebSocket (TCP), so EVERYTHING is delivered reliably and in order, whatever the transfer mode asks for.
## UNRELIABLE and UNRELIABLE_ORDERED packets are sent as ordinary ordered frames (the mode and channel ride in the header and are
## reported unchanged by get_packet_mode()/get_packet_channel()). Cost: head-of-line blocking after packet loss, so keep unreliable
## streams (movement snapshots) small and rate-limited by the sender. The relay limits packets to 64 KiB.
## Events (peer_connected / peer_disconnected) are queued and emitted from _poll(), i.e. from SceneMultiplayer's poll.

const MAX_PACKET := 65536
const HOST_ID := 1

var _lobby: DmLobbyClient
var _status: int = MultiplayerPeer.CONNECTION_DISCONNECTED
var _unique_id := 0
var _server := false
var _target := 0
var _channel := 0
var _mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refuse := false
var _peers := {}                       # connected remote peer ids
var _inbox: Array = []                 # {src, mode, channel, data}
var _events: Array = []                # {connect: bool, id: int}
## Why the session ended, set before peer_disconnected(1) fires on a client ("host_left", "kicked", "idle", "shutdown", "connection lost: ...").
var close_reason := ""

## Attach as the host of the session `lobby` just created. The peer is CONNECTED at once.
func host(lobby: DmLobbyClient) -> Error:
	if lobby.state != DmLobbyClient.State.IN_SESSION_HOST:
		return ERR_UNCONFIGURED
	_attach(lobby)
	_server = true
	_unique_id = HOST_ID
	_status = MultiplayerPeer.CONNECTION_CONNECTED
	return OK

## Attach as a client of the session `lobby` just joined. The peer is CONNECTED at once; peer_connected(1) fires on the first poll.
func join(lobby: DmLobbyClient) -> Error:
	if lobby.state != DmLobbyClient.State.IN_SESSION_CLIENT:
		return ERR_UNCONFIGURED
	_attach(lobby)
	_server = false
	_unique_id = lobby.peer_id
	_status = MultiplayerPeer.CONNECTION_CONNECTED
	_events.append({"connect": true, "id": HOST_ID})
	_peers[HOST_ID] = true
	return OK

func get_lobby() -> DmLobbyClient:
	return _lobby

func _attach(lobby: DmLobbyClient) -> void:
	_lobby = lobby
	close_reason = ""
	lobby.packet_sink = _on_packet
	lobby.peer_joined.connect(_on_peer_joined)
	lobby.peer_left.connect(_on_peer_left)
	lobby.session_closed.connect(_on_session_closed)
	lobby.left_session.connect(_on_session_closed.bind("left"))
	lobby.disconnected.connect(_on_lobby_disconnected)

func _detach() -> void:
	if _lobby == null:
		return
	_lobby.packet_sink = Callable()
	for pair in [[_lobby.peer_joined, _on_peer_joined], [_lobby.peer_left, _on_peer_left], [_lobby.session_closed, _on_session_closed],
			[_lobby.disconnected, _on_lobby_disconnected]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])
	for c in _lobby.left_session.get_connections():
		_lobby.left_session.disconnect(c["callable"])
	_lobby = null

func _on_packet(src: int, mode: int, channel: int, payload: PackedByteArray) -> void:
	if _status != MultiplayerPeer.CONNECTION_CONNECTED or not _peers.has(src):
		return
	_inbox.append({"src": src, "mode": mode, "channel": channel, "data": payload})

func _on_peer_joined(id: int, _name: String) -> void:
	if not _server or _peers.has(id):
		return
	if _refuse:
		_lobby.kick(id)
		return
	_peers[id] = true
	_events.append({"connect": true, "id": id})

func _on_peer_left(id: int, _reason: String) -> void:
	if _peers.erase(id):
		_events.append({"connect": false, "id": id})

func _on_session_closed(reason: String) -> void:
	_end(reason)

func _on_lobby_disconnected(reason: String) -> void:
	_end("connection lost: " + reason)

func _end(reason: String) -> void:
	if _status == MultiplayerPeer.CONNECTION_DISCONNECTED or _ending:
		return
	close_reason = reason
	for id in _peers.keys():
		_events.append({"connect": false, "id": id})
	_peers.clear()
	_inbox.clear()
	_ending = true # status flips to DISCONNECTED in _poll after the queued peer_disconnected events were emitted

var _ending := false

# ---------------------------------------------------------------------------------------------------------------- virtuals

func _poll() -> void:
	if _lobby != null:
		_lobby.poll()
	while not _events.is_empty():
		var e: Dictionary = _events.pop_front()
		if e["connect"]:
			peer_connected.emit(e["id"])
		else:
			peer_disconnected.emit(e["id"])
	if _ending and _events.is_empty():
		_ending = false
		_status = MultiplayerPeer.CONNECTION_DISCONNECTED
		_detach()

func _get_available_packet_count() -> int:
	return _inbox.size()

func _get_packet_script() -> PackedByteArray:
	if _inbox.is_empty():
		return PackedByteArray()
	var p: Dictionary = _inbox.pop_front()
	return p["data"]

# SceneMultiplayer asks for the sender/mode/channel of the NEXT packet BEFORE it calls get_packet(), so these describe the queue head.
func _get_packet_peer() -> int:
	return _inbox[0]["src"] if not _inbox.is_empty() else 0

func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return (_inbox[0]["mode"] if not _inbox.is_empty() else MultiplayerPeer.TRANSFER_MODE_RELIABLE) as MultiplayerPeer.TransferMode

func _get_packet_channel() -> int:
	return _inbox[0]["channel"] if not _inbox.is_empty() else 0

func _put_packet_script(p_buffer: PackedByteArray) -> Error:
	if _status != MultiplayerPeer.CONNECTION_CONNECTED or _lobby == null or _ending:
		return ERR_UNCONFIGURED
	if p_buffer.size() > MAX_PACKET:
		return ERR_OUT_OF_MEMORY
	if not _server:
		# Clients only talk to the host (the relay drops anything else; Godot's server relay forwards client-to-client RPCs).
		return _lobby.send_packet(HOST_ID, _mode, _channel, p_buffer)
	if _target == 0:
		return _lobby.send_packet(0, _mode, _channel, p_buffer)
	if _target > 0:
		if not _peers.has(_target):
			return ERR_INVALID_PARAMETER
		return _lobby.send_packet(_target, _mode, _channel, p_buffer)
	var err := OK
	for id in _peers.keys():   # negative target = everyone except -target
		if id != -_target:
			var e := _lobby.send_packet(id, _mode, _channel, p_buffer)
			if e != OK:
				err = e
	return err

func _get_max_packet_size() -> int:
	return MAX_PACKET

func _set_target_peer(p_peer: int) -> void:
	_target = p_peer

func _set_transfer_channel(p_channel: int) -> void:
	_channel = p_channel

func _get_transfer_channel() -> int:
	return _channel

func _set_transfer_mode(p_mode: MultiplayerPeer.TransferMode) -> void:
	_mode = p_mode

func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _mode as MultiplayerPeer.TransferMode

func _get_unique_id() -> int:
	return _unique_id

func _is_server() -> bool:
	return _server

func _is_server_relay_supported() -> bool:
	return true

func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return _status as MultiplayerPeer.ConnectionStatus

func _set_refuse_new_connections(p_enable: bool) -> void:
	_refuse = p_enable
	if _server and _lobby != null:
		_lobby.set_open(not p_enable)

func _is_refusing_new_connections() -> bool:
	return _refuse

func _disconnect_peer(p_peer: int, _p_force: bool) -> void:
	if _server and _peers.has(p_peer) and _lobby != null:
		_lobby.kick(p_peer)   # the relay answers with peer_left, which raises peer_disconnected
	elif not _server and p_peer == HOST_ID:
		_close()

func _close() -> void:
	if _status == MultiplayerPeer.CONNECTION_DISCONNECTED and _lobby == null:
		return
	var lobby := _lobby
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED
	_peers.clear()
	_inbox.clear()
	_events.clear()
	_ending = false
	_detach()
	if lobby != null and lobby.in_session():
		lobby.leave()
		lobby.poll() # flush the leave frame   # the lobby socket stays open so the caller can list/join another session; call lobby.close() to drop it
