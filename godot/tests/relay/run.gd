extends SceneTree
## Relay integration test. Headless:  godot --headless --path godot --script res://tests/relay/run.gd
## Starts the lobby service (server/death-muffin/lobby) on 127.0.0.1:<a random free port> with a TEST jwt secret, then runs a host and three clients
## as separate headless Godot processes (peer_main.gd) through DmRelayPeer, plus this process as a 5th joiner that must be refused.
## Needs `node` and `npm install` done in server/death-muffin/lobby; otherwise it prints a skip line and exits 0.

const SECRET := "relay-test-secret-not-a-real-one"
const HOST := "127.0.0.1"

var pass_count := 0
var fail_count := 0
var pids: Array = []
var tmp := ""
var port := 0

func ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		pass_count += 1
	else:
		fail_count += 1
		print("FAIL: ", label, " ", extra)

func _initialize() -> void:
	_main.call_deferred()

func _finish() -> void:
	if tmp != "":
		for f in DirAccess.get_files_at(tmp):
			DirAccess.remove_absolute(tmp.path_join(f))
		DirAccess.remove_absolute(tmp)
	for pid in pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	print("%d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)

func _wait(cond: Callable, timeout_s: float = 15.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > timeout_s * 1000.0:
			return false
		await create_timer(0.05).timeout
	return true

func _log_of(name: String) -> String:
	var p := tmp.path_join(name + ".log")
	return FileAccess.get_file_as_string(p) if FileAccess.file_exists(p) else ""

func _has(name: String, needle: String) -> bool:
	return _log_of(name).contains(needle)

func _spawn(role: String, token: String, log_name: String, sid: String = "", label: String = "") -> int:
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/relay/peer_main.gd", "--",
		role, "ws://%s:%d" % [HOST, port], token, tmp.path_join(log_name + ".log"), sid, label]
	var pid := OS.create_process(OS.get_executable_path(), args)
	pids.append(pid)
	return pid

func _lobby_client(token: String) -> DmLobbyClient:
	var c := DmLobbyClient.new()
	c.connect_to_lobby("ws://%s:%d" % [HOST, port], token)
	return c

func _pump(c: DmLobbyClient) -> void:
	c.poll()

func _main() -> void:
	var lobby_dir := ProjectSettings.globalize_path("res://").path_join("../server/death-muffin/lobby").simplify_path()
	var out := []
	if OS.execute("node", ["-v"], out) != OK or not FileAccess.file_exists(lobby_dir.path_join("node_modules/ws/package.json")):
		print("relay: SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm install`)")
		print("0 passed, 0 failed (skipped)")
		quit(0)
		return
	tmp = OS.get_user_data_dir().path_join("relay_test_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(tmp)
	port = DmTestPorts.free_tcp_port()
	if port == 0:
		print("relay: SKIPPED (no free port in 40000-49999)")
		print("0 passed, 0 failed (skipped)")
		quit(0)
		return
	OS.set_environment("DM_LOBBY_JWT_SECRET", SECRET)
	OS.set_environment("DM_LOBBY_PORT", str(port))
	OS.set_environment("DM_LOBBY_HOST", HOST)
	OS.set_environment("DM_LOBBY_QUIET", "1")
	var node_pid := OS.create_process("node", [lobby_dir.path_join("src/index.js")])
	pids.append(node_pid)
	var tok := func(id: int, name: String) -> String: return RelayTestJwt.mint(SECRET, id, name)

	# --- auth ---------------------------------------------------------------------------------------------------------
	var good := _lobby_client(tok.call(100, "tester"))
	var good_ok := [false]
	good.authenticated.connect(func(_i: int, _n: String) -> void: good_ok[0] = true)
	var t0 := Time.get_ticks_msec()
	while not good_ok[0] and Time.get_ticks_msec() - t0 < 10000:
		await create_timer(0.1).timeout
		if good.state == DmLobbyClient.State.CLOSED:
			good = _lobby_client(tok.call(100, "tester"))  # service still starting: retry
			good.authenticated.connect(func(_i: int, _n: String) -> void: good_ok[0] = true)
		good.poll()
	ok(good_ok[0], "lobby service up and token accepted")
	if not good_ok[0]:
		_finish()
		return
	ok(good.username == "tester" and good.account_id == 100 and good.max_players == 4, "ready message carries identity + max players")
	var bad := _lobby_client(RelayTestJwt.mint("wrong-secret", 101, "mallory"))
	var bad_reason := [""]
	bad.connection_failed.connect(func(r: String) -> void: bad_reason[0] = r)
	await _wait(func() -> bool: bad.poll(); return bad_reason[0] != "", 5.0)
	ok(bad_reason[0] != "", "bad-secret token rejected", bad_reason[0])

	# --- session with host + 3 clients over real Godot multiplayer ---------------------------------------------------
	good.request_list()
	var listed := [null]
	good.sessions_listed.connect(func(s: Array) -> void: listed[0] = s)
	await _wait(func() -> bool: good.poll(); return listed[0] != null, 3.0)
	ok(listed[0] != null and listed[0].size() == 0, "empty lobby lists no sessions")

	_spawn("host", tok.call(1, "hostess"), "host")
	ok(await _wait(func() -> bool: return _has("host", "SESSION ")), "host created a session", _log_of("host"))
	var sid := ""
	for line in _log_of("host").split("\n"):
		if line.begins_with("SESSION "):
			sid = line.substr(8).strip_edges()
	ok(_has("host", "PEER_HOST 0"), "DmRelayPeer.host() ok")
	listed[0] = null
	good.request_list()
	await _wait(func() -> bool: good.poll(); return listed[0] != null, 3.0)
	var info: Dictionary = listed[0][0] if listed[0] != null and listed[0].size() == 1 else {}
	ok(info.get("name", "") == "relay-test" and info.get("host", "") == "hostess" and info.get("area", "") == "hollow-graves" and int(info.get("players", 0)) == 1 and int(info.get("max", 0)) == 4, "session listed with name/host/area/players", str(listed[0]))

	var labels := ["A", "B", "C"]
	for i in 3:
		_spawn("client", tok.call(2 + i, "player" + labels[i]), labels[i], sid, labels[i])
		ok(await _wait(func() -> bool: return _has(labels[i], "CONNECTED ")), "client %s connected through the relay" % labels[i], _log_of(labels[i]))
		ok(_has(labels[i], "CONNECTED %d" % (2 + i)), "client %s got unique id %d" % [labels[i], 2 + i])
		ok(_has(labels[i], "PEER_CONNECTED 1"), "client %s saw peer_connected(1)" % labels[i])
		ok(await _wait(func() -> bool: return _has("host", "PEER_CONNECTED %d" % (2 + i))), "host saw peer_connected(%d)" % (2 + i))

	# 5th player: this process, must be refused
	var fifth := _lobby_client(tok.call(200, "fifth"))
	var five_err := [""]
	await _wait(func() -> bool: fifth.poll(); return fifth.state == DmLobbyClient.State.LOBBY, 5.0)
	fifth.lobby_error.connect(func(code: String, _m: String, _r: String) -> void: five_err[0] = code)
	fifth.join_session(sid)
	await _wait(func() -> bool: fifth.poll(); return five_err[0] != "", 5.0)
	ok(five_err[0] == "full", "5th joiner refused (full)", five_err[0])
	ok(fifth.state == DmLobbyClient.State.LOBBY, "refused joiner stays in the lobby")

	# RPCs both ways
	ok(await _wait(func() -> bool: return _has("host", "BCAST_SENT")), "host got hello RPC from all 3 clients", _log_of("host"))
	for l in labels:
		ok(_has("host", "HELLO %d %s" % [2 + labels.find(l), l]), "client->host RPC from " + l)
		ok(await _wait(func() -> bool: return _has(l, "WELCOME %d (sender 1)" % (2 + labels.find(l)))), "host->client rpc_id reply to " + l, _log_of(l))
		ok(await _wait(func() -> bool: return _has(l, "BCAST 42 [1, 2, 3, 250]")), "host->all broadcast incl. PackedByteArray arg reached " + l, _log_of(l))
	ok(await _wait(func() -> bool: return _has("host", "PING_U 7 from 4")), "unreliable_ordered RPC arrives (reliable underneath)", _log_of("host"))
	ok(await _wait(func() -> bool: return _has("C", "C2C from-A via-sender 2")), "client->client RPC works via Godot server relay", _log_of("C"))

	# client disconnect: B leaves once released
	ok(await _wait(func() -> bool: return _has("B", "B_WAITING")), "B got the broadcast", _log_of("B"))
	FileAccess.open(tmp.path_join("release_b"), FileAccess.WRITE).close()
	ok(await _wait(func() -> bool: return _has("host", "PEER_DISCONNECTED 3")), "host sees peer_disconnected when a client leaves", _log_of("host"))
	ok(not _has("host", "PEER_DISCONNECTED 2") and not _has("host", "PEER_DISCONNECTED 4"), "other clients stay connected")
	fifth.join_session(sid)
	five_err[0] = ""
	await _wait(func() -> bool: fifth.poll(); return fifth.state == DmLobbyClient.State.IN_SESSION_CLIENT or five_err[0] != "", 5.0)
	ok(fifth.state == DmLobbyClient.State.IN_SESSION_CLIENT and fifth.peer_id == 5, "freed slot can be taken; peer ids are not reused", "state=%d id=%d err=%s" % [fifth.state, fifth.peer_id, five_err[0]])

	# host disconnect ends the session for everyone, with a reason
	var closed_reason := [""]
	fifth.session_closed.connect(func(r: String) -> void: closed_reason[0] = r)
	FileAccess.open(tmp.path_join("release_host"), FileAccess.WRITE).close() # lets the host run its shutdown
	ok(await _wait(func() -> bool: return _has("host", "HOST_CLOSING"), 20.0), "host finished the scripted exchange", _log_of("host"))
	ok(await _wait(func() -> bool: return _has("A", "SERVER_GONE host_left") and _has("C", "SERVER_GONE host_left")), "clients get server_disconnected with reason host_left", _log_of("A") + _log_of("C"))
	await _wait(func() -> bool: fifth.poll(); return closed_reason[0] != "", 5.0)
	ok(closed_reason[0] == "host_left", "lobby-level joiner told session_closed(host_left)", closed_reason[0])
	listed[0] = null
	good.request_list()
	await _wait(func() -> bool: good.poll(); return listed[0] != null, 3.0)
	ok(listed[0] != null and listed[0].size() == 0, "session is gone from the list")

	# everything exited cleanly
	for l in ["host", "A", "B", "C"]:
		ok(not _has(l, "TIMEOUT") and not _has(l, "SCRIPT ERROR"), l + " child had no timeout/script errors", _log_of(l))

	# cleanup
	good.close()
	fifth.close()
	_finish()
