class_name DmSession
extends Node
## Listen-server session on Godot high-level multiplayer, independent of the transport (any MultiplayerPeer: ENet, DmRelayPeer, ...).
##
## The node must be inside the tree, at the SAME NodePath on every peer (RPC + spawner paths are resolved relative to it), before
## host()/join(). Uses `multiplayer`, so it also works in a SceneMultiplayer branch (`get_tree().set_multiplayer(api, root_path)`).
##
## Replication design (D1: the host is authoritative):
##  - Clients send movement INTENT by RPC (`_rpc_move_to` reliable, `_rpc_move_dir` unreliable); the host validates (sender must own the
##    body, finite values, arena clamp, speed is a host constant) and simulates the body.
##  - The host broadcasts ONE batched snapshot RPC (all bodies: x, z, yaw) at SNAPSHOT_HZ, unreliable_ordered. Chosen over
##    MultiplayerSynchronizer because: one packet per tick instead of one per node, we control the interpolation buffer, nothing depends
##    on per-node authority/visibility config, and it behaves identically over a relay peer. Clients render bodies 100 ms in the past.
##  - Body lifetime uses MultiplayerSpawner (spawn_function), so late joiners get existing bodies and despawns replicate automatically.
##  - The roster (peer_id, name, discipline) is host-owned and re-broadcast reliably on every change.
## Solo / offline (D4): host(OfflineMultiplayerPeer.new()) is a 1-player session with no sockets; same code path, snapshots are skipped.
## Host-as-player: the host is peer 1 and has a body too (set `character_name`/`discipline_id` before host()). MAX_PLAYERS includes it.

signal player_joined(peer_id: int)
signal player_left(peer_id: int)
signal session_started
signal session_ended(reason: String)

const MAX_PLAYERS := 4  ## D2
const PROTOCOL := 1
const SNAPSHOT_HZ := 20.0
const INTERP_DELAY := 0.1
const MOVE_SPEED := 5.0
const ARENA_HALF := 40.0
## Half-extent a click-to-move target may be (the arena bound by default; a game whose world is larger, DmNextGame, raises it: the Warren lies at x -72, the Depths at x 150).
var move_half: float = ARENA_HALF
const HELLO_TIMEOUT := 5.0
const REFUSE_FLUSH := 0.3  ## grace between sending a refusal and dropping the peer, so the reason arrives

enum State { IDLE, HOSTING, JOINING, ACTIVE, ENDING }

var character_name: String = "Player"
var discipline_id: String = ""
## Seams for a game built on the session (both default to the arena behaviour): `body_factory: Callable() -> DmSessionBody` makes the
## player body on EVERY peer (spawner spawn_function), `spawn_origin` shifts the spawn ring (set before host()).
var body_factory: Callable = Callable()
var spawn_origin: Vector3 = Vector3.ZERO
var rejected_intents: int = 0  ## host: intents ignored (not owner / bad values); for tests and cheat logging

var _state: int = State.IDLE
var _is_host: bool = false
var _roster: Dictionary = {}  ## peer_id -> {peer_id, name, discipline}
var _players: Node3D
var _spawner: MultiplayerSpawner
var _tick_acc: float = 0.0
var _refusing: Dictionary = {}


func _ready() -> void:
	_players = Node3D.new()
	_players.name = "Players"
	add_child(_players)
	_spawner = MultiplayerSpawner.new()
	_spawner.name = "Spawner"
	add_child(_spawner)
	_spawner.spawn_path = NodePath("../Players")
	_spawner.spawn_function = Callable(self, "_spawn_body")


# ---- public API ---------------------------------------------------------------------------------------------------------------

func is_host() -> bool:
	return _is_host and _state != State.IDLE


func is_active() -> bool:
	return _state == State.HOSTING or _state == State.ACTIVE


func get_my_id() -> int:
	return multiplayer.get_unique_id() if _state != State.IDLE else 0


func get_roster() -> Array:
	var out: Array = _roster.values()
	out.sort_custom(func(a, b): return a["peer_id"] < b["peer_id"])
	return out


func get_body(peer_id: int) -> DmSessionBody:
	return _players.get_node_or_null("P%d" % peer_id) as DmSessionBody


func get_bodies() -> Array:
	return _players.get_children()


func host(peer: MultiplayerPeer) -> int:
	if _state != State.IDLE or not is_inside_tree():
		return ERR_ALREADY_IN_USE
	multiplayer.multiplayer_peer = peer
	_is_host = true
	_state = State.HOSTING
	_connect_signals()
	_accept(1, character_name, discipline_id)
	session_started.emit()
	player_joined.emit(1)
	return OK


func join(peer: MultiplayerPeer) -> int:
	if _state != State.IDLE or not is_inside_tree():
		return ERR_ALREADY_IN_USE
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return ERR_CANT_CONNECT
	multiplayer.multiplayer_peer = peer
	_is_host = false
	_state = State.JOINING
	_connect_signals()
	return OK


## Leave / close. The host announces the end to clients and waits a moment so it arrives; `await` is optional.
func leave() -> void:
	if _state == State.IDLE or _state == State.ENDING:
		return
	if _is_host:
		_state = State.ENDING
		_rpc_session_closed.rpc("host closed the session")
		await get_tree().create_timer(0.25).timeout
	_teardown("left the session")


## Ask the host to walk my body to a ground point. `body_id` exists only so tests can forge intents; leave it 0 (= my own body).
func request_move_to(point: Vector3, body_id: int = 0) -> void:
	if _state == State.IDLE:
		return
	var b := body_id if body_id != 0 else get_my_id()
	if multiplayer.is_server():
		_apply_move_to(1, b, point)
	else:
		_rpc_move_to.rpc_id(1, b, point)


## Direction intent (held-key movement): resend at least every 0.2 s while held; send ZERO (or stop resending) to stop.
func request_move_dir(dir: Vector3, body_id: int = 0) -> void:
	if _state == State.IDLE:
		return
	var b := body_id if body_id != 0 else get_my_id()
	if multiplayer.is_server():
		_apply_move_dir(1, b, dir)
	else:
		_rpc_move_dir.rpc_id(1, b, dir)


## Standing mouse-aim: turn my body to `yaw` (radians, atan2(dx, dz)). The host ignores it while the body walks.
func request_face(yaw: float, body_id: int = 0) -> void:
	if _state == State.IDLE:
		return
	var b := body_id if body_id != 0 else get_my_id()
	if multiplayer.is_server():
		_apply_face(1, b, yaw)
	else:
		_rpc_face.rpc_id(1, b, yaw)


# ---- plumbing -----------------------------------------------------------------------------------------------------------------

func _exit_tree() -> void:
	if _state != State.IDLE:
		_teardown("session node removed")


func _connect_signals() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _disconnect_signals() -> void:
	for pair in [[multiplayer.peer_connected, _on_peer_connected], [multiplayer.peer_disconnected, _on_peer_disconnected],
			[multiplayer.connected_to_server, _on_connected_to_server], [multiplayer.connection_failed, _on_connection_failed],
			[multiplayer.server_disconnected, _on_server_disconnected]]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])


func _teardown(reason: String) -> void:
	if _state == State.IDLE:
		return
	_disconnect_signals()
	var peer := multiplayer.multiplayer_peer
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()   # the engine's default (never null): lingering nodes asking get_unique_id() keep working
	for c in _players.get_children():
		_players.remove_child(c)
		c.queue_free()
	_roster.clear()
	_refusing.clear()
	_state = State.IDLE
	_is_host = false
	_tick_acc = 0.0
	session_ended.emit(reason)


func _on_connected_to_server() -> void:
	_rpc_hello.rpc_id(1, PROTOCOL, character_name, discipline_id)


func _on_connection_failed() -> void:
	_teardown("could not connect to the host")


func _on_server_disconnected() -> void:
	if _state != State.ENDING:
		_teardown("lost connection to the host")


func _on_peer_connected(id: int) -> void:
	# ENet's congestion throttle drops UNRELIABLE packets when the round-trip time spikes (a hitch on either side, a loaded machine) and
	# can sit at 0 for seconds: boss / enemy / thrall state (unreliable_ordered, 20 Hz) then stopped arriving altogether (a client kept the
	# boss's full hp while the host was at half). Deceleration 0 = the throttle never goes down; reliable traffic keeps its own congestion control.
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet != null:
		var pp := enet.get_peer(id)
		if pp != null:
			pp.throttle_configure(5000, 2, 0)
	if not _is_host:
		return
	# A peer that never says hello is dropped (it holds no slot, but should not linger).
	get_tree().create_timer(HELLO_TIMEOUT).timeout.connect(func():
		if _is_host and _state == State.HOSTING and not _roster.has(id) and id in multiplayer.get_peers() and not _refusing.has(id):
			_refuse(id, "handshake timed out"))


func _on_peer_disconnected(id: int) -> void:
	_refusing.erase(id)
	if not _is_host or _state != State.HOSTING:
		return
	if _roster.has(id):
		_remove_player(id)


static func _clean(s: String, max_len: int) -> String:
	var out := ""
	for ch in s.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			out += ch
	return out.substr(0, max_len)


func _spawn_point(index: int) -> Vector3:
	var a := TAU * float(index) / float(MAX_PLAYERS)
	return spawn_origin + Vector3(cos(a), 0.0, sin(a)) * 3.0


func _accept(id: int, nm: String, disc: String) -> void:
	_roster[id] = {"peer_id": id, "name": nm, "discipline": disc}
	_spawner.spawn({"id": id, "name": nm, "disc": disc, "pos": _spawn_point(_roster.size() - 1)})


func _spawn_body(data: Variant) -> Node:
	var b: DmSessionBody = body_factory.call() if body_factory.is_valid() else DmSessionBody.new()
	b.setup(int(data["id"]), str(data["name"]), str(data["disc"]), data["pos"])
	b.simulated = multiplayer.is_server()
	return b


func _remove_player(id: int) -> void:
	_roster.erase(id)
	var b := get_body(id)
	if b != null:
		b.queue_free()  # the spawner replicates the despawn
	_rpc_roster.rpc(get_roster())
	player_left.emit(id)


func _refuse(id: int, reason: String) -> void:
	_refusing[id] = true
	_rpc_refused.rpc_id(id, reason)
	get_tree().create_timer(REFUSE_FLUSH).timeout.connect(func():
		if _is_host and _state == State.HOSTING and id in multiplayer.get_peers():
			multiplayer.multiplayer_peer.disconnect_peer(id))


func _physics_process(delta: float) -> void:
	if _state != State.HOSTING:
		return
	for c in _players.get_children():
		(c as DmSessionBody).step_host(delta, MOVE_SPEED, ARENA_HALF)
	_tick_acc += delta
	if _tick_acc >= 1.0 / SNAPSHOT_HZ:
		_tick_acc = fmod(_tick_acc, 1.0 / SNAPSHOT_HZ)
		_send_snapshot()


func _send_snapshot() -> void:
	if multiplayer.get_peers().is_empty():
		return
	var ids := PackedInt32Array()
	var data := PackedFloat32Array()
	for c in _players.get_children():
		var b := c as DmSessionBody
		ids.append(b.owner_peer)
		data.append(b.position.x)
		data.append(b.position.z)
		data.append(b.yaw)
	_rpc_snapshot.rpc(ids, data)


# ---- intent validation (host) -------------------------------------------------------------------------------------------------

func _valid_vec(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


func _owned_body(sender: int, body_id: int) -> DmSessionBody:
	var b := get_body(body_id)
	if b == null or b.owner_peer != sender or sender != body_id:
		rejected_intents += 1
		return null
	return b


func _apply_move_to(sender: int, body_id: int, p: Vector3) -> void:
	if _state != State.HOSTING:
		return
	var b := _owned_body(sender, body_id)
	if b == null:
		return
	if not _valid_vec(p):
		rejected_intents += 1
		return
	b.set_move_target(Vector3(clampf(p.x, -move_half, move_half), 0.0, clampf(p.z, -move_half, move_half)))


func _apply_move_dir(sender: int, body_id: int, d: Vector3) -> void:
	if _state != State.HOSTING:
		return
	var b := _owned_body(sender, body_id)
	if b == null:
		return
	if not _valid_vec(d):
		rejected_intents += 1
		return
	b.set_move_dir(d)


func _apply_face(sender: int, body_id: int, yaw: float) -> void:
	if _state != State.HOSTING:
		return
	var b := _owned_body(sender, body_id)
	if b == null:
		return
	if not is_finite(yaw):
		rejected_intents += 1
		return
	b.set_facing(yaw)


# ---- RPCs ---------------------------------------------------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(protocol: int, nm: String, disc: String) -> void:
	if not multiplayer.is_server() or _state != State.HOSTING:
		return
	var id := multiplayer.get_remote_sender_id()
	if _roster.has(id) or _refusing.has(id):
		return
	if protocol != PROTOCOL:
		_refuse(id, "version mismatch (host %d, you %d)" % [PROTOCOL, protocol])
		return
	if _roster.size() >= MAX_PLAYERS:
		_refuse(id, "session is full (%d/%d players)" % [_roster.size(), MAX_PLAYERS])
		return
	_accept(id, _clean(nm, 24) if _clean(nm, 24) != "" else "Player", _clean(disc, 32))
	_rpc_roster.rpc(get_roster())
	player_joined.emit(id)


@rpc("authority", "call_remote", "reliable")
func _rpc_roster(list: Array) -> void:
	var old: Dictionary = _roster
	_roster = {}
	for e in list:
		_roster[int(e["peer_id"])] = e
	if _state == State.JOINING and _roster.has(multiplayer.get_unique_id()):
		_state = State.ACTIVE
		session_started.emit()
	if _state != State.ACTIVE:
		return
	for id in _roster:
		if not old.has(id):
			player_joined.emit(id)
	for id in old:
		if not _roster.has(id):
			player_left.emit(id)


@rpc("authority", "call_remote", "reliable")
func _rpc_refused(reason: String) -> void:
	_teardown(reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_session_closed(reason: String) -> void:
	_teardown(reason)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_snapshot(ids: PackedInt32Array, data: PackedFloat32Array) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	for i in range(ids.size()):
		var b := get_body(ids[i])
		if b != null and not b.simulated:
			b.push_sample(t, Vector3(data[i * 3], 0.0, data[i * 3 + 1]), data[i * 3 + 2])


@rpc("any_peer", "call_remote", "reliable")
func _rpc_move_to(body_id: int, p: Vector3) -> void:
	if multiplayer.is_server():
		_apply_move_to(multiplayer.get_remote_sender_id(), body_id, p)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_move_dir(body_id: int, d: Vector3) -> void:
	if multiplayer.is_server():
		_apply_move_dir(multiplayer.get_remote_sender_id(), body_id, d)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_face(body_id: int, yaw: float) -> void:
	if multiplayer.is_server():
		_apply_face(multiplayer.get_remote_sender_id(), body_id, yaw)
