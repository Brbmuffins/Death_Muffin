extends SceneTree
## Realtime co-op tests. Headless:  godot --headless --path godot --script res://tests/realtime/run.gd
## Part 1 (always): golden fixtures from the TS (npx vite-node tools/godot/fixtures-realtime.ts) + Socket.IO packet unit tests.
## Part 2 (opt-in, LOCAL only): DM_RT_INTEGRATION=1 starts server/realtime on 127.0.0.1:$DM_RT_PORT (default 5300) from this worktree
## plus Node socket.io-client peers, and drives two-client / snapshot / disconnect / reconnect scenarios. Needs `node`, and
## DM_RT_NODE_PATH = a node_modules dir that holds socket.io, jsonwebtoken, dotenv (the worktree has none). Never touches live services.

var pass_count := 0
var fail_count := 0
var fx: Dictionary

func _initialize() -> void:
	_main()

func ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		pass_count += 1
	else:
		fail_count += 1
		print("FAIL: ", label, " ", extra)

func deep_eq(a: Variant, b: Variant, eps: float = 1e-9) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
		return absf(float(a) - float(b)) <= eps
	if ta != tb:
		return false
	if ta == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not deep_eq(a[k], b[k], eps):
				return false
		return true
	if ta == TYPE_ARRAY:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not deep_eq(a[i], b[i], eps):
				return false
		return true
	return a == b

## Compare ignoring keys whose TS value was `undefined`/absent and ours is null/absent.
func strip_nulls(v: Variant) -> Variant:
	if v is Dictionary:
		var o := {}
		for k in v:
			if v[k] != null:
				o[k] = strip_nulls(v[k])
		return o
	if v is Array:
		return (v as Array).map(strip_nulls)
	return v

func _path(rel: String) -> String:
	return ProjectSettings.globalize_path("res://" + rel)

# --- part 1 ---------------------------------------------------------------------------------------------------------------------------

func test_urls_and_policy() -> void:
	ok(DmSioSocket.build_url("https://muffindevelopment.com", "/death-muffin/rt/socket.io") == "wss://muffindevelopment.com/death-muffin/rt/socket.io/?EIO=4&transport=websocket", "prod url")
	ok(DmSioSocket.build_url("http://127.0.0.1:5300/", "") == "ws://127.0.0.1:5300/socket.io/?EIO=4&transport=websocket", "local default path")
	for i in fx["delays"]["rejoin"].size():
		ok(DmRtClient.rejoin_delay_ms(i) == int(fx["delays"]["rejoin"][i]), "rejoin delay %d" % i)
		ok(DmRtClient.first_connect_delay_ms(i) == int(fx["delays"]["first"][i]), "first delay %d" % i)
	for c: Dictionary in fx["retry"]:
		ok(DmRtClient.is_retryable_error(c["msg"], c["mode"]) == c["expected"], "retryable '%s' %s" % [c["msg"], c["mode"]])
	var r: Dictionary = fx["rejoin"]
	DmRtRejoinStore.save_rejoin("abc", 1000)
	for c: Dictionary in r["at"]:
		ok(DmRtRejoinStore.load_rejoin(int(c["now"])) == (str(c["expected"]) if c.get("expected") != null else ""), "rejoin store at %d" % int(c["now"]))
	DmRtRejoinStore.clear_rejoin()
	ok(DmRtRejoinStore.load_rejoin(1000) == "", "rejoin cleared")

func test_encode() -> void:
	for i in fx["encodeCases"].size():
		var c: Dictionary = fx["encodeCases"][i]
		var inp: Dictionary = DmJson.normalise(c["input"].duplicate(true))
		var got := DmSnapshot.make_snapshot(inp, c["full"])
		# Round trip through JSON like the wire does, so int/float representation matches.
		got = DmJson.parse(JSON.stringify(got))
		var exp: Dictionary = DmJson.normalise(c["expected"].duplicate(true))
		ok(deep_eq(strip_nulls(got), strip_nulls(exp), 1e-7), "make_snapshot case %d" % i)

func mirror_view(m: DmWorldMirror) -> Dictionary:
	var by_id := func(d: Dictionary) -> Array:
		var ids := d.keys()
		ids.sort()
		return ids.map(func(k: Variant) -> Variant: return d[k])
	var dep := []
	var dk := m.depleted.keys()
	dk.sort()
	for k in dk:
		dep.append([k, m.depleted[k]])
	return {"time": m.time, "waveTier": m.wave_tier, "difficulty": m.difficulty, "vows": m.vows, "ascension": m.ascension(),
		"enemies": by_id.call(m.enemies), "thralls": by_id.call(m.thralls), "corpses": by_id.call(m.corpses), "zones": by_id.call(m.zones),
		"depleted": dep, "boss": m.boss_state}

func sorted_by_id(a: Array) -> Array:
	var b := a.duplicate()
	b.sort_custom(func(x: Variant, y: Variant) -> bool: return int(x["id"]) < int(y["id"]))
	return b

func test_mirror() -> void:
	for i in fx["mirrorCases"].size():
		var m := DmWorldMirror.new()
		var steps: Array = fx["mirrorCases"][i]["steps"]
		for s in steps.size():
			var st: Dictionary = steps[s]
			m.apply_snapshot(DmJson.normalise(st["snapshot"].duplicate(true)))
			m.apply_events(DmJson.normalise(st["events"].duplicate(true)))
			m.update(float(st["dt"]))
			var exp: Dictionary = DmJson.normalise(st["state"].duplicate(true))
			var got := mirror_view(m)
			var dep_sorted: Array = exp["depleted"].duplicate()
			dep_sorted.sort_custom(func(a: Array, b: Array) -> bool: return str(a[0]) < str(b[0]))
			exp["depleted"] = dep_sorted
			exp["enemies"] = sorted_by_id(exp["enemies"])
			exp["thralls"] = sorted_by_id(exp["thralls"])
			exp["corpses"] = sorted_by_id(exp["corpses"])
			exp["zones"] = sorted_by_id(exp["zones"])
			# Compare the fields the TS carries (we hold a few extra view fields as null / the same defaults).
			var good := true
			for key in ["time", "waveTier", "difficulty", "vows", "ascension", "corpses", "zones", "depleted", "boss"]:
				if not deep_eq(strip_nulls(got[key]), strip_nulls(exp[key]), 1e-7):
					good = false
					print("  mirror ", i, "/", s, " mismatch in ", key)
			for key in ["enemies", "thralls"]:
				if got[key].size() != exp[key].size():
					good = false
					print("  mirror ", i, "/", s, " ", key, " count ", got[key].size(), " vs ", exp[key].size())
					continue
				for j in exp[key].size():
					var ge: Dictionary = strip_nulls(got[key][j])
					var ee: Dictionary = strip_nulls(exp[key][j])
					for f in ee:
						if not deep_eq(ge.get(f), ee[f], 1e-7):
							good = false
							print("  mirror ", i, "/", s, " ", key, "[", j, "].", f, " got ", ge.get(f), " want ", ee[f])
							break
			ok(good, "mirror seq %d step %d" % [i, s])

func test_coalescer() -> void:
	for ci in fx["coalescer"].size():
		var c: Dictionary = fx["coalescer"][ci]
		var sent: Array = []
		var co := DmEventCoalescer.new(func(b: Array) -> void: sent.append(b), float(c["perSec"]), int(c["maxBatch"]))
		for p: Array in c["pushes"]:
			var evs: Array = (p[0] as Array).map(func(n: Variant) -> Dictionary: return {"t": "x", "n": int(n)})
			co.push(evs, float(p[1]))
		var exp: Array = DmJson.normalise(c["sends"].duplicate(true))
		ok(deep_eq(sent, exp), "coalescer %d sends" % ci)
		ok(co.waiting() == int(c["waiting"]), "coalescer %d waiting" % ci)

func test_offline() -> void:
	# Solo with the server down: failures are DmResults, senders are inert.
	var rt := DmRtClient.new()
	rt.send_move({"x": 1})
	rt.send_chat("hi")
	rt.send_snapshot({})
	ok(not rt.is_connected_to_world() and not rt.is_host(), "offline flags")
	rt.base_url = ""
	rt.ws_path = ""
	var r: DmResult = await rt.connect_to_world("tok", {})
	ok(not r.ok and r.error == "Realtime service not configured" and not DmRtClient.is_retryable_error(r.error, "first"), "not configured is final")
	rt.base_url = "http://127.0.0.1:5399"
	rt.ws_path = ""
	r = await rt.connect_to_world("", {})
	ok(not r.ok and r.error == "Not authenticated", "no token is final")
	r = await rt.connect_to_world("offline:x", {})
	ok(not r.ok and DmRtClient.is_retryable_error(r.error, "first"), "server down is retryable: " + r.error)
	ok(r.error == DmRtClient.UNREACHABLE, "server down message is the unreachable text", r.error)

# --- part 2: integration ------------------------------------------------------------------------------------------------------------

var server_pid := -1
var peer_pids: Array = []
var port := 5300
var url := ""
var logdir := ""

func wait_until(cond: Callable, timeout_s: float = 8.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(timeout_s * 1000.0):
		if cond.call():
			return true
		await process_frame
	return cond.call()

func wait_server(timeout_s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(timeout_s * 1000.0):
		if await server_up():
			return
		await wait_s(0.3)

func wait_s(s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(s * 1000.0):
		await process_frame

func start_server() -> void:
	var node_path := OS.get_environment("DM_RT_NODE_PATH")
	OS.set_environment("NODE_PATH", node_path)
	OS.set_environment("REALTIME_PORT", str(port))
	OS.set_environment("REALTIME_HOST", "127.0.0.1")
	OS.set_environment("DEV_TRUST_TOKENS", "1")
	OS.set_environment("ENV_FILE", "/nonexistent/none.env")
	OS.set_environment("NODE_ENV", "test")
	server_pid = OS.create_process("node", [_path("../server/realtime/server.js")])

func stop_server() -> void:
	if server_pid > 0:
		OS.kill(server_pid)
		server_pid = -1

func start_peer(instance: String, name: String, tag: String = "") -> String:
	var log_file := logdir.path_join(name + ".log")
	var pid := OS.create_process("node", [_path("tests/realtime/peer.mjs"), url, instance, name, log_file, tag if tag != "" else name])
	peer_pids.append(pid)
	return log_file

func read_log(file: String) -> Array:
	var out: Array = []
	if not FileAccess.file_exists(file):
		return out
	for line in FileAccess.get_file_as_string(file).split("\n", false):
		var v: Variant = DmJson.parse(line)
		if v is Dictionary:
			out.append(v)
	return out

func log_has(file: String, ev: String, pred: Callable = Callable()) -> bool:
	for e in read_log(file):
		if e.get("ev") == ev and (not pred.is_valid() or pred.call(e)):
			return true
	return false

func server_up() -> bool:
	var rt := DmRtClient.new()
	rt.base_url = url
	rt.ws_path = ""
	var r: DmResult = await rt.connect_to_world("offline:probe", {"instance": "probe-room", "characterId": 1, "classIndex": 0, "x": 0, "z": 0, "facing": 0})
	rt.disconnect_from_world()
	return r.ok

## Unsigned JWT-shaped token: the local server runs with DEV_TRUST_TOKENS=1 (decode only). Never a real credential.
func fake_jwt(account: int, sid: String) -> String:
	var b := func(d: Dictionary) -> String:
		return Marshalls.raw_to_base64(JSON.stringify(d).to_utf8_buffer()).replace("+", "-").replace("/", "_").trim_suffix("=").trim_suffix("=")
	return "%s.%s.sig" % [b.call({"alg": "none", "typ": "JWT"}), b.call({"accountId": account, "username": "sess%d" % account, "sid": sid})]

func join_req(instance: String, cid: int = 1) -> Dictionary:
	return {"instance": instance, "characterId": cid, "classIndex": 3, "level": 12, "x": 1.0, "z": 2.0, "facing": 0.5, "gear": {"main_hand": "bone_staff"}}

func integration() -> void:
	port = int(OS.get_environment("DM_RT_PORT")) if OS.get_environment("DM_RT_PORT") != "" else 5300
	url = "http://127.0.0.1:%d" % port
	logdir = OS.get_environment("DM_RT_LOGDIR") if OS.get_environment("DM_RT_LOGDIR") != "" else "/tmp/dm-rt-test"
	DirAccess.make_dir_recursive_absolute(logdir)
	for f in DirAccess.get_files_at(logdir):
		DirAccess.remove_absolute(logdir.path_join(f))
	if OS.get_environment("DM_RT_NODE_PATH") == "":
		ok(false, "DM_RT_NODE_PATH must point at a node_modules dir with socket.io")
		return
	print("-- integration: local server ", url)

	# 1. server down at first: first-connect failure is retryable, and DmRtReconnector recovers once it appears
	var rt := DmRtClient.new()
	rt.base_url = url
	rt.ws_path = ""
	var r: DmResult = await rt.connect_to_world("offline:godot1", join_req("room1"))
	ok(not r.ok and DmRtClient.is_retryable_error(r.error, "first"), "server down first connect retryable: " + r.error)
	var rc := DmRtReconnector.new("first", func() -> DmResult: return await rt.connect_to_world("offline:godot1", join_req("room1")))
	var timers: Array = []
	rc.timer_factory = func(ms: int, fn: Callable) -> void: timers.append([ms, fn])
	var retries: Array = []
	rc.retry.connect(func(n: int, ms: int, err: String) -> void: retries.append([n, ms, err]))
	var done := [null]
	rc.succeeded.connect(func(res: DmResult) -> void: done[0] = res)
	rc.start()
	ok(retries.size() == 1 and retries[0][1] == 10000, "reconnector first delay 10s")
	timers.pop_back()[1].call()  # fire it: server still down
	await wait_until(func() -> bool: return retries.size() == 2, 10.0)
	ok(retries.size() == 2 and retries[1][1] == 20000 and rc.is_active(), "still down -> retry in 20s (first-connect backoff)")
	start_server()
	await wait_server(10.0)
	ok(await server_up(), "local server up")
	var peerA_log := start_peer("room1", "peerA")
	await wait_until(func() -> bool: return log_has(peerA_log, "joined"), 8.0)
	ok(log_has(peerA_log, "joined"), "peer A joined (host)")
	timers.pop_back()[1].call()  # the pending 20s timer fires; server is up now
	await wait_until(func() -> bool: return done[0] != null, 8.0)
	ok(done[0] != null and done[0].ok, "reconnector connected once the server appeared")
	var jr: Dictionary = done[0].data if done[0] != null and done[0].ok else {}

	# 2. two clients see each other; snapshots + events + moves + chat + intents flow
	ok(jr.get("players", []).size() == 2, "join result lists both players")
	ok(jr.get("self", {}).get("classIndex") == 3 and jr.get("self", {}).get("level") == 12, "self record echoes class/level")
	var peer_rec: Dictionary = {}
	for p: Dictionary in jr.get("players", []):
		if p["id"] != jr["self"]["id"]:
			peer_rec = p
	ok(peer_rec.get("classIndex") == 2 and peer_rec.get("gear", {}).get("main_hand") == "bone_staff", "peer record has class + gear")
	ok(jr.get("hostId") == peer_rec.get("id") and not rt.is_host() and rt.instance == "room1", "peer is host, we are guest")
	ok(rt.self_id == jr["self"]["id"] and rt.is_connected_to_world(), "self_id/connected")
	ok(log_has(peerA_log, "player:join", func(e: Dictionary) -> bool: return e["p"]["id"] == rt.self_id and e["p"]["classIndex"] == 3), "peer saw us join")
	var got_snaps: Array = []
	var got_moves: Array = []
	var chats: Array = []
	rt.snapshot_received.connect(func(s: Dictionary) -> void: got_snaps.append(s))
	rt.player_moved.connect(func(u: Dictionary) -> void: got_moves.append(u))
	rt.chat_received.connect(func(m: Dictionary) -> void: chats.append(m))
	var mirror := DmWorldMirror.new()
	rt.snapshot_received.connect(func(s: Dictionary) -> void: mirror.apply_snapshot(s))
	await wait_until(func() -> bool: return got_snaps.size() >= 3 and got_moves.size() >= 3, 6.0)
	ok(got_snaps.size() >= 3, "received live snapshots (%d)" % got_snaps.size())
	ok(rt.stats["snapIn"] >= got_snaps.size() and rt.stats["moveIn"] >= got_moves.size() and got_snaps.size() > 0, "stats counters")
	ok(got_moves.size() >= 3 and got_moves[0]["id"] == peer_rec["id"] and got_moves[0].has("hpFrac"), "received peer moves")
	ok(mirror.enemies.has(7) and mirror.enemies[7]["def"] == "robber" and mirror.enemies[7]["elite"] == true and mirror.enemies[7]["affix"] == "hungering", "snapshot applied to mirror (enemy)")
	ok(mirror.thralls.has(200) and mirror.thralls[200]["owner"] == peer_rec["id"] and mirror.thralls[200]["empowered"] == true, "snapshot applied to mirror (thrall)")
	ok(mirror.difficulty == "hard" and mirror.wave_tier == 3 and mirror.depleted.has("tree_1"), "mirror dials + depleted")
	rt.send_move({"x": 5.0, "z": 6.0, "facing": 0.25, "moving": true, "hpFrac": 0.75, "level": 12})
	rt.send_chat("hello from godot")
	rt.send_intent({"t": "hit", "ids": [7], "dmg": 25, "fracture": 0, "boss": false})
	rt.send_gear({"main_hand": "grave_staff"})
	rt.send_snapshot({"t": 1, "waveTier": 0, "enemies": [], "thralls": [], "boss": {}})  # guest: server drops it
	await wait_until(func() -> bool: return log_has(peerA_log, "world:intent") and log_has(peerA_log, "chat:message") and log_has(peerA_log, "player:gear"), 5.0)
	ok(log_has(peerA_log, "player:move", func(e: Dictionary) -> bool: return e["p"]["x"] == 5 and e["p"]["id"] == rt.self_id), "peer saw our move")
	ok(log_has(peerA_log, "chat:message", func(e: Dictionary) -> bool: return e["p"]["text"] == "hello from godot"), "peer saw our chat")
	ok(chats.size() == 1 and chats[0]["text"] == "hello from godot", "chat echoed to sender")
	ok(log_has(peerA_log, "world:intent", func(e: Dictionary) -> bool: return e["p"]["from"] == rt.self_id and e["p"]["intent"]["t"] == "hit" and e["p"]["intent"]["dmg"] == 25), "host peer got our intent")
	ok(log_has(peerA_log, "player:gear", func(e: Dictionary) -> bool: return e["p"]["gear"]["main_hand"] == "grave_staff"), "peer saw gear change")

	# 3. we leave -> peer sees it; we rejoin (disconnect/reconnect by hand)
	var left_id := rt.self_id
	rt.disconnect_from_world()
	ok(not rt.is_connected_to_world(), "disconnect_from_world")
	await wait_until(func() -> bool: return log_has(peerA_log, "player:leave", func(e: Dictionary) -> bool: return e["p"]["id"] == left_id), 5.0)
	ok(log_has(peerA_log, "player:leave", func(e: Dictionary) -> bool: return e["p"]["id"] == left_id), "peer saw us leave")
	await wait_s(0.3)
	r = await rt.connect_to_world("offline:godot1", join_req("room1"))
	ok(r.ok and r.data["players"].size() == 2 and rt.self_id != left_id, "manual rejoin works (new socket id)")
	ok(r.ok and r.data["snapshot"] != null and r.data["snapshot"]["waveTier"] == 3, "late joiner gets the host's last snapshot in the join result")

	# 4. same account twice in one world is rejected with the player-readable error
	var rt_dup := DmRtClient.new()
	rt_dup.base_url = url
	rt_dup.ws_path = ""
	var rd: DmResult = await rt_dup.connect_to_world("offline:godot1", join_req("room1"))
	ok(not rd.ok and rd.error.to_lower().contains("already in"), "duplicate join rejected: " + rd.error)
	ok(DmRtClient.is_retryable_error(rd.error, "rejoin") and not DmRtClient.is_retryable_error(rd.error, "first"), "duplicate join retryable only when rejoining")

	# 5. server restart: disconnect signal, DmRtReconnector('rejoin') backs off, then rejoins with the roster restored
	var disc := [0]
	rt.disconnected.connect(func() -> void: disc[0] += 1)
	var rj := DmRtReconnector.new("rejoin", func() -> DmResult: return await rt.connect_to_world("offline:godot1", join_req("room1")))
	var rtimers: Array = []
	rj.timer_factory = func(ms: int, fn: Callable) -> void: rtimers.append([ms, fn])
	var rretries: Array = []
	rj.retry.connect(func(n: int, ms: int, err: String) -> void: rretries.append([n, ms, err]))
	var rdone := [null]
	rj.succeeded.connect(func(res: DmResult) -> void: rdone[0] = res)
	stop_server()
	await wait_until(func() -> bool: return disc[0] == 1, 8.0)
	ok(disc[0] == 1 and not rt.is_connected_to_world(), "disconnected signal fired once when the server died")
	rt.send_move({"x": 1.0, "z": 1.0, "facing": 0.0, "moving": false, "hpFrac": 1.0})  # inert while down
	rj.start()
	ok(rretries.size() == 1 and rretries[0][1] == 1000, "rejoin backoff starts at 1s")
	rtimers.pop_back()[1].call()
	await wait_until(func() -> bool: return rretries.size() == 2, 10.0)
	ok(rretries.size() == 2 and rretries[1][1] == 2000, "second rejoin delay 2s (server still down): " + str(rretries))
	start_server()
	await wait_server(10.0)
	await wait_s(1.5)  # the peer rejoins every 300 ms and becomes host of the fresh world
	rtimers.pop_back()[1].call()
	await wait_until(func() -> bool: return rdone[0] != null or not rj.is_active(), 10.0)
	ok(rdone[0] != null and rdone[0].ok, "reconnector rejoined after server restart", str(rretries))
	if rdone[0] != null and rdone[0].ok:
		ok(rdone[0].data["players"].size() == 2, "roster restored after restart")
		var snaps_after := [0]
		rt.snapshot_received.connect(func(_s: Dictionary) -> void: snaps_after[0] += 1)
		await wait_until(func() -> bool: return snaps_after[0] >= 2, 5.0)
		ok(snaps_after[0] >= 2, "snapshots flow again after the restart")

	# 6. we are the host: our snapshot (built by DmSnapshot) reaches a guest peer, and host migration hands the room over
	rt.disconnect_from_world()
	var rt_h := DmRtClient.new()
	rt_h.base_url = url
	rt_h.ws_path = ""
	var rh: DmResult = await rt_h.connect_to_world("offline:godotH", join_req("room2", 5))
	ok(rh.ok and rh.data["hostId"] == rt_h.self_id and rt_h.is_host(), "first into a fresh world is host")
	var sim := {"time": 42.0, "waveTier": 4, "difficulty": "easy", "ascension": 0, "vows": {}, "bossState": {"active": false}, "depleted": [],
		"enemies": [{"id": 9, "def": "hound", "x": 1.234, "z": 2.0, "facing": 0.0, "hp": 10.4, "maxHp": 20, "state": "move", "stateT": 0.0, "speed": 3, "scale": 1, "area": "graveyard", "level": 5, "elite": true, "moving": true}],
		"thralls": [], "zones": [], "corpses": []}
	rt_h.send_snapshot(DmSnapshot.make_snapshot(sim, true))
	var peerB_log := start_peer("room2", "peerB", "peerB")
	await wait_until(func() -> bool: return log_has(peerB_log, "joined"), 6.0)
	ok(log_has(peerB_log, "joined", func(e: Dictionary) -> bool: return e["snapshotT"] == 42), "guest peer's join result carried our snapshot")
	rt_h.send_snapshot(DmSnapshot.make_snapshot(sim, false))
	await wait_until(func() -> bool: return log_has(peerB_log, "world:snapshot", func(e: Dictionary) -> bool: return e["t"] == 42 and e["enemies"] == 1), 5.0)
	ok(log_has(peerB_log, "world:snapshot", func(e: Dictionary) -> bool: return e["t"] == 42 and e["enemies"] == 1), "guest peer received our live snapshot")
	rt_h.send_events([{"t": "death", "id": 9}])
	await wait_until(func() -> bool: return log_has(peerB_log, "world:events"), 5.0)
	ok(log_has(peerB_log, "world:events", func(e: Dictionary) -> bool: return e["p"][0]["t"] == "death"), "guest peer received our events")
	rt_h.disconnect_from_world()
	await wait_until(func() -> bool: return log_has(peerB_log, "room:host", func(e: Dictionary) -> bool: return e["p"]["snapshot"] != null), 5.0)
	ok(log_has(peerB_log, "room:host", func(e: Dictionary) -> bool: return e["p"]["snapshot"] != null and e["p"]["snapshot"]["waveTier"] == 4), "host leaving promoted the peer with our last snapshot")

	# 7. one session per account: a newer login evicts the older socket (session:replaced), an older login is refused (final error)
	var old_c := DmRtClient.new()
	old_c.base_url = url
	old_c.ws_path = ""
	var replaced := [0]
	var old_disc := [0]
	old_c.session_replaced.connect(func() -> void: replaced[0] += 1)
	old_c.disconnected.connect(func() -> void: old_disc[0] += 1)
	var ro: DmResult = await old_c.connect_to_world(fake_jwt(77, "1000-aaa"), join_req("room3", 31))
	ok(ro.ok, "old session joined")
	var new_c := DmRtClient.new()
	new_c.base_url = url
	new_c.ws_path = ""
	var rn: DmResult = await new_c.connect_to_world(fake_jwt(77, "2000-bbb"), join_req("room3", 31))
	ok(rn.ok, "newer session joined")
	await wait_until(func() -> bool: return old_disc[0] > 0, 5.0)
	# NB: the relay's session:replaced push can be lost to the close that follows it (WebSocketPeer), so only the disconnect is asserted here.
	ok(old_disc[0] == 1 and not old_c.is_connected_to_world(), "older socket was disconnected by the newer login", str([replaced, old_disc]))
	var stale := DmRtClient.new()
	stale.base_url = url
	stale.ws_path = ""
	var stale_replaced := [0]
	stale.session_replaced.connect(func() -> void: stale_replaced[0] += 1)
	var rs: DmResult = await stale.connect_to_world(fake_jwt(77, "1500-ccc"), join_req("room3", 31))
	ok(not rs.ok and rs.error.contains("opened somewhere else") and not DmRtClient.is_retryable_error(rs.error, "rejoin"), "older login refused, final: " + rs.error)
	ok(stale_replaced[0] == 1, "refused older login raises session_replaced")
	new_c.disconnect_from_world()
	rt.disconnect_from_world()

func _main() -> void:
	var f := FileAccess.open("res://tests/realtime/fixtures/realtime.json", FileAccess.READ)
	if f == null:
		print("fixtures missing: run tools/godot/gen-fixtures.sh (npx vite-node tools/godot/fixtures-realtime.ts)")
		quit(2)
		return
	fx = JSON.parse_string(f.get_as_text())
	test_urls_and_policy()
	test_encode()
	test_mirror()
	test_coalescer()
	await test_offline()
	if OS.get_environment("DM_RT_INTEGRATION") == "1":
		await integration()
		for pid in peer_pids:
			OS.kill(pid)
		stop_server()
	else:
		print("(integration skipped: set DM_RT_INTEGRATION=1 DM_RT_NODE_PATH=<node_modules with socket.io>)")
	print("realtime tests: %d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)
