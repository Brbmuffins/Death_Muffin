extends Node
## The RPC surface + scripted behaviour of one test participant (see peer_main.gd). Same node path/name on every process.

var role := ""
var url := ""
var token := ""
var logfile := ""
var session_id := ""
var label := ""

var lobby := DmLobbyClient.new()
var peer: DmRelayPeer
var hellos := {}
var dones := {}
var left := {}
var unreliable_seen := 0
var c2c_seen := false
var my_id := 0
var age := 0.0
var quit_at := -1.0
var closing := false
var b_waiting := false

func _log(line: String) -> void:
	var f := FileAccess.open(logfile, FileAccess.READ_WRITE if FileAccess.file_exists(logfile) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(line)
	f.close()

func _ready() -> void:
	_log("START " + role)
	multiplayer.peer_connected.connect(func(id: int) -> void: _log("PEER_CONNECTED %d" % id))
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(func() -> void:
		_log("SERVER_GONE " + (peer.close_reason if peer != null else "?"))
		quit_at = age + 0.3)
	lobby.authenticated.connect(_on_authenticated)
	lobby.connection_failed.connect(func(r: String) -> void: _log("CONNECT_FAILED " + r); quit_at = age + 0.2)
	lobby.lobby_error.connect(func(code: String, msg: String, _r: String) -> void: _log("LOBBY_ERROR %s %s" % [code, msg]); quit_at = age + 0.2)
	lobby.session_created.connect(_on_created)
	lobby.session_joined.connect(_on_joined)
	var err := lobby.connect_to_lobby(url, token)
	if err != OK:
		_log("CONNECT_FAILED err %d" % err)
		quit_at = 0.1

func _process(delta: float) -> void:
	age += delta
	if peer == null:
		lobby.poll()
	if quit_at >= 0.0 and age >= quit_at:
		get_tree().quit()
	if age > 40.0:
		_log("TIMEOUT")
		get_tree().quit(1)
	if b_waiting and FileAccess.file_exists(logfile.get_base_dir().path_join("release_b")):
		b_waiting = false
		peer.close()
		lobby.close()
		_log("LEFT")
		quit_at = age + 0.3
	if role == "host" and not closing:
		if dones.has(2) and dones.has(4) and left.has(3) and FileAccess.file_exists(logfile.get_base_dir().path_join("release_host")):
			closing = true
			_log("HOST_CLOSING")
			peer.close()
			quit_at = age + 0.4

func _on_authenticated(_id: int, uname: String) -> void:
	_log("AUTH " + uname)
	if role == "host":
		lobby.create_session("relay-test", "hollow-graves")
	else:
		lobby.join_session(session_id)

func _on_created(info: Dictionary, _code: String) -> void:
	peer = DmRelayPeer.new()
	_log("PEER_HOST " + str(peer.host(lobby)))
	multiplayer.multiplayer_peer = peer
	_log("SESSION " + str(info["id"]))

func _on_joined(_info: Dictionary, pid: int) -> void:
	peer = DmRelayPeer.new()
	my_id = pid
	_log("PEER_JOIN " + str(peer.join(lobby)))
	multiplayer.multiplayer_peer = peer

func _on_connected_to_server() -> void:
	_log("CONNECTED %d" % multiplayer.get_unique_id())
	hello.rpc_id(1, label)
	ping_u.rpc_id(1, 7)

func _on_peer_disconnected(id: int) -> void:
	_log("PEER_DISCONNECTED %d" % id)
	left[id] = true

# --- RPCs ---------------------------------------------------------------------------------------------------------------

@rpc("any_peer", "reliable")
func hello(who: String) -> void:
	var s := multiplayer.get_remote_sender_id()
	hellos[s] = who
	_log("HELLO %d %s" % [s, who])
	welcome.rpc_id(s, s)
	if hellos.size() == 3:
		bcast.rpc(42, PackedByteArray([1, 2, 3, 250]))
		_log("BCAST_SENT")

@rpc("any_peer", "unreliable_ordered")
func ping_u(v: int) -> void:
	unreliable_seen += 1
	_log("PING_U %d from %d" % [v, multiplayer.get_remote_sender_id()])

@rpc("authority", "reliable")
func welcome(my_assigned_id: int) -> void:
	_log("WELCOME %d (sender %d)" % [my_assigned_id, multiplayer.get_remote_sender_id()])

@rpc("authority", "reliable")
func bcast(v: int, blob: PackedByteArray) -> void:
	_log("BCAST %d %s" % [v, str(Array(blob))])
	if label == "A":
		c2c.rpc_id(4, "from-A")
		done.rpc_id(1, "A")
	elif label == "B":
		_log("B_WAITING") # B leaves cleanly once run.gd releases it: the host must see peer_disconnected(3)
		b_waiting = true

@rpc("any_peer", "reliable")
func c2c(msg: String) -> void:
	_log("C2C %s via-sender %d" % [msg, multiplayer.get_remote_sender_id()])
	done.rpc_id(1, "C")

@rpc("any_peer", "reliable")
func done(tag: String) -> void:
	var s := multiplayer.get_remote_sender_id()
	dones[s] = tag
	_log("DONE %d %s" % [s, tag])
